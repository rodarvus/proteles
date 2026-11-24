import Foundation

/// Native port of the MUSHclient Consider miniwindow
/// (AardCrowley/Mushclient-Consider): a floating list of the room's mobs with
/// difficulty tiers, click-to-attack, and a `conwall` batch sweep. The pure
/// ``ConsiderModel`` does the parsing/state; this plugin orchestrates — sending
/// `consider all` when the list goes stale (gated on player state), gagging
/// the consider output, handling `conw…` commands, and publishing a
/// ``ConsiderSnapshot`` for the panel.
///
/// Data source: like the original, the list comes from parsing `consider all`
/// output (Aardwolf has no GMCP room-occupant list). It's the state model's
/// first consumer (S0b item 2, #84; `docs/plans/S0B_ITEM2_PROPOSAL.md`):
///
/// - **Auto-refresh** (``ConsiderAutoMode``, `conw on|area|off`; on by
///   default) considers on room entry, when a mob arrives or flees, and when
///   the area repops — never mid-combat, running or note-writing. `area`
///   switches itself off on leaving the zone, as Areia_Consider does.
/// - **A consider anyone sends is adopted**: S&D's smartscan fallback or the
///   player's own `consider` refreshes the list without another command.
/// - **Keywords** resolve through the model's ``MobKeywordBook`` (the
///   player's override, then S&D's, then the guess); `conw kw` sets one.
/// - A room the model knows is empty of mobs clears the list.
public struct ConsiderFeature: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.consider",
        name: "Consider",
        author: "Proteles",
        version: "1.0",
        summary: "Floating list of the room's mobs with difficulty tiers; click to attack, conwall to sweep."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Shows the room's mobs and how each cons against you, in a floating panel. "
                + "It refreshes as you move and as mobs come and go; `conw area` does so only until "
                + "you leave the area, and `conw off` only when you type `conw`. "
                + "Click a mob to attack it.",
            commands: [
                .init(syntax: "conw", summary: "Refresh the list now (run `consider all`)."),
                .init(
                    syntax: "conw on|area|off",
                    summary: "Auto-refresh everywhere, until you leave this area, or never."
                ),
                .init(syntax: "conw cmd <command>", summary: "Set the default attack command (e.g. `kill`)."),
                .init(syntax: "conw mode skill|cast|pro", summary: "How attack targets are formatted."),
                .init(
                    syntax: "conw <n> [command]",
                    summary: "Attack list mob #n (optionally with a command)."
                ),
                .init(
                    syntax: "conw kw <n> [keyword]",
                    summary: "Set the keyword used to target list mob #n in this area; no keyword clears it."
                ),
                .init(syntax: "conwall", summary: "Attack every mob that passes the filters.")
            ]
        )
    }

    /// `char.status.state` values in which it's safe to auto-`consider`: 3
    /// (standing/playing) and 11 (AFK/idle, still in-world) — never login (1),
    /// note-writing (5), running (12), or combat (8). Mirrors AsciiMap.
    static let playingStates: Set<Int> = [3, 11]

    var model = ConsiderModel()
    var settings = ConsiderSettings()
    /// The model's keyword book and occupants, from ``onStateChange(_:changed:)``.
    var book = MobKeywordBook()
    var occupants: Occupants?
    /// When the last consider list was taken, adopted or our own, so a later
    /// occupant change doesn't adopt the same list again.
    var lastNamedAt: Date?

    var playerState: Int?
    var playerAlign: Int?
    var currentZone: String?
    var currentRoom: Int?
    var isSafeRoom = false
    var statusNote: String?
    /// A refresh came due while not in a playing state (a room entered or a
    /// mob arriving mid-combat); it fires when we return to one.
    var pendingConsider = false
    /// The mapper is walking us somewhere (its 999 `kinda_busy`, until
    /// `ok_you_can_go_now`). Between a portal and a `run`, and on a run's
    /// first room, the game still says state 3, so this, not the state, is
    /// what holds a refresh back mid-walk.
    var mapperRunning = false

    public init() {}

    // MARK: - GMCP

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        switch package.lowercased() {
        case "char.status":
            onCharStatus(json)
        case "room.info":
            onRoomInfo(json)
        case "comm.repop":
            onRepop(json)
        default:
            []
        }
    }

    // MARK: - State model (S0b item 2)

    public mutating func onStateChange(
        _ state: ActionableState, changed: Set<ActionableState.Entity>
    ) -> [ScriptEffect] {
        book = state.keywords
        occupants = state.occupants
        var changedList = false
        if changed.contains(.keywords) {
            let (book, zone) = (book, currentZone)
            model.rekey { book.resolve($0, area: zone) }
            changedList = true
        }
        if changed.contains(.occupants), let occupants {
            changedList = follow(occupants) || changedList
        }
        return changedList ? [publishEffect()] : []
    }

    /// Adopt a consider list someone else sent for this room, or clear the
    /// list when the room is known to have no mobs. Returns whether the list
    /// changed.
    private mutating func follow(_ occupants: Occupants) -> Bool {
        if let named = newConsiderList(occupants) {
            lastNamedAt = named.at
            // Our own run is still being parsed (gagged) by the model; adopt
            // only someone else's.
            guard !model.considering else { return false }
            model.adopt(named)
            statusNote = nil
            return true
        }
        guard occupants.mobs?.isEmpty == true, !model.considering, !model.mobs.isEmpty else { return false }
        model.clear()
        return true
    }

    /// This room's consider list, when it's one not seen before.
    func newConsiderList(_ occupants: Occupants) -> NamedOccupants? {
        guard let named = occupants.named, named.source == .consider, named.room == currentRoom,
              named.at != lastNamedAt
        else { return nil }
        return named
    }

    // MARK: - Consider lifecycle

    /// End-of-output sentinel echoed after `consider all` (the server bounces it
    /// back verbatim). A distinctive tag — not a bare word like the old "nhm" —
    /// so ``onLine(_:)`` can gag it unconditionally without risk of hiding real
    /// MUD text. Mirrors dinv's `{ DINV fence N }` round-trip fence.
    static let endSentinel = "{ consider }"

    /// Start a `consider all` capture, or short-circuit with a status note for a
    /// safe room / ignored zone (clearing the list, sending nothing). Mirrors the
    /// plugin's `Send_Consider_Internal`.
    mutating func beginConsiderSequence() -> [ScriptEffect] {
        if let zone = currentZone, model.ignoredZones.contains(zone) {
            model.clear()
            statusNote = "Ignoring zone \(zone)"
            return [publishEffect()]
        }
        if isSafeRoom {
            model.clear()
            statusNote = "Safe room"
            return [publishEffect()]
        }
        statusNote = nil
        model.beginConsider()
        // After `consider all`, echo a tagged sentinel the server bounces back:
        // the consider lines stream (gagged), then `{ consider }` arrives and we
        // finalise on it. The tag is unmistakably ours, so it's always gagged in
        // `onLine` — a duplicate/late one (two auto-refreshes in flight) can't
        // leak into the output, as a bare "nhm" could.
        return [
            .sendNoEcho("consider all"),
            .sendNoEcho("echo \(Self.endSentinel)"),
            publishEffect()
        ]
    }

    // MARK: - Line ingestion

    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)

        // The end-of-output sentinel (echoed back by the server). Always gag it:
        // the tag is unmistakably ours, so a duplicate/late one (two refreshes in
        // flight) can't leak. Finalise the capture only when one is actually open.
        if trimmed == Self.endSentinel {
            guard model.considering else { return .init(gag: true) }
            model.endConsider()
            return .init(gag: true, effects: [publishEffect()])
        }
        if model.considering, trimmed == "You see no one here but yourself!" {
            return .init(gag: true)
        }
        let (zone, book) = (currentZone, book)
        let outcome = model.ingestLine(line.text, zone: zone) { book.resolve($0, area: zone) }
        switch outcome {
        case .considered:
            return .init(gag: true, effects: [publishEffect()])
        case .mobArrived, .mobFled:
            // The original's `auto_consider_misc` group: who is here changed.
            return .init(effects: [publishEffect()] + refreshIfAuto())
        case .mobLeft, .mobKilled:
            return .init(effects: [publishEffect()])
        case .ignored:
            return .init()
        }
    }

    // MARK: - Commands (conw…)

    public mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower == "conwall" { return batch() }
        guard lower == "conw" || lower.hasPrefix("conw ") else { return nil }

        let rest = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return beginConsiderSequence() } // manual refresh

        var tokens = rest.split(separator: " ").map(String.init)
        let head = tokens.removeFirst()
        let arg = tokens.joined(separator: " ")
        // A leading number is an attack on that list position.
        if let position = Int(head) {
            return attack(position: position, override: arg.isEmpty ? nil : arg)
        }
        return dispatchSubcommand(head.lowercased(), tokens: tokens, arg: arg)
    }

    /// Route a `conw <subcommand>` to its handler. Split from `handleCommand`
    /// to keep each within the complexity budget.
    private mutating func dispatchSubcommand(
        _ head: String, tokens: [String], arg: String
    ) -> [ScriptEffect] {
        switch head {
        case "on", "area", "off": return setAutoMode(head)
        case "cmd":
            if !arg.isEmpty { settings.defaultCommand = arg }
            return configChanged()
        case "mode":
            if let mode = ConsiderExecuteMode(rawValue: arg.lowercased()) { settings.executeMode = mode }
            return configChanged()
        case "skip": return setSkip(tokens)
        case "level": return setLevel(tokens)
        case "kw": return setKeyword(tokens)
        default: return [helpNote()]
        }
    }

    /// `conw kw <n> [keyword]`: set (or, with no keyword, clear) the
    /// player's keyword for list mob *n*, in this area (S0b item 2, Q4).
    private func setKeyword(_ tokens: [String]) -> [ScriptEffect] {
        guard let first = tokens.first, let position = Int(first), model.mobs.indices.contains(position - 1)
        else { return [.echo("Consider: conw kw <n> [keyword] — n is a position in the list.")] }
        guard let zone = currentZone else { return [.echo("Consider: the area isn't known yet.")] }
        let name = model.mobs[position - 1].name
        let keyword = tokens.dropFirst().joined(separator: " ")
        let note = keyword.isEmpty
            ? "Consider: cleared your keyword for \(name)."
            : "Consider: \(name) will be targeted as '\(keyword)' in \(zone)."
        return [.setMobKeyword(name: name, area: zone, keyword: keyword.isEmpty ? nil : keyword), .echo(note)]
    }

    private mutating func setLevel(_ tokens: [String]) -> [ScriptEffect] {
        if tokens.count == 2, let lo = Int(tokens[0]), let hi = Int(tokens[1]) {
            settings.options.minLevel = min(lo, hi)
            settings.options.maxLevel = max(lo, hi)
        }
        return configChanged()
    }

    private mutating func setSkip(_ tokens: [String]) -> [ScriptEffect] {
        guard tokens.count == 2 else { return [helpNote()] }
        let on = tokens[1].lowercased() == "on"
        switch tokens[0].lowercased() {
        case "evil": settings.options.skipEvil = on
        case "good": settings.options.skipGood = on
        case "neutral": settings.options.skipNeutral = on
        case "sanc", "sanctuary": settings.options.skipSanctuary = on
        case "align": settings.options.skipAlignAuto = on
        default: return [helpNote()]
        }
        return configChanged()
    }

    private mutating func attack(position: Int, override: String?) -> [ScriptEffect] {
        let command = override ?? settings.defaultCommand
        guard let line = model.attackCommand(position: position, command: command, mode: settings.executeMode)
        else { return [publishEffect()] }
        return [.execute(line), publishEffect()]
    }

    private mutating func batch() -> [ScriptEffect] {
        ConsiderModel.autoAlign(&settings.options, playerAlign: playerAlign)
        let plan = model.planBatch(
            options: settings.options, defaultCommand: settings.defaultCommand, mode: settings.executeMode
        )
        var effects: [ScriptEffect] = switch plan {
        case .noMobs: [.echo("Consider: no mobs to attack.")]
        case .noValidTargets: [.echo("Consider: no valid targets.")]
        case .aoe(let commands), .targets(let commands): commands.map { .execute($0) }
        }
        effects.append(publishEffect())
        return effects
    }

    /// Republish + persist after a config change.
    func configChanged() -> [ScriptEffect] {
        [publishEffect(), .persistPluginState(id: metadata.id)]
    }

    private func helpNote() -> ScriptEffect {
        .echo("Consider: conw | conw on/area/off | conw cmd <command> | conw mode skill/cast/pro | "
            + "conw <n> [command] | conw kw <n> [keyword] | conwall")
    }

    // MARK: - Snapshot

    private func snapshot() -> ConsiderSnapshot {
        ConsiderSnapshot(
            mobs: model.mobs,
            defaultCommand: settings.defaultCommand,
            executeMode: settings.executeMode,
            auto: settings.auto,
            options: settings.options,
            statusNote: statusNote
        )
    }

    func publishEffect() -> ScriptEffect {
        .updateConsider(snapshot())
    }

    // MARK: - Persistence

    public var persistentState: Data? {
        try? JSONEncoder().encode(settings)
    }

    public mutating func restore(from data: Data) {
        if let restored = try? JSONDecoder().decode(ConsiderSettings.self, from: data) {
            settings = restored
        }
    }
}
