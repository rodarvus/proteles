import Foundation

/// A snapshot of the Consider feature's state for the floating panel to render —
/// the mob list plus the controls' current values. Passed by value (no JSON),
/// mirroring how `.updateMap` ships captured map lines.
public struct ConsiderSnapshot: Sendable, Equatable {
    public var mobs: [ConsiderMob]
    public var defaultCommand: String
    public var executeMode: ConsiderExecuteMode
    public var enabled: Bool
    public var options: ConsiderBatchOptions
    /// A one-line status shown instead of the list (`"Safe room"`,
    /// `"Ignoring zone <x>"`), or nil when the list is live.
    public var statusNote: String?

    public init(
        mobs: [ConsiderMob] = [],
        defaultCommand: String = "kill",
        executeMode: ConsiderExecuteMode = .skill,
        enabled: Bool = true,
        options: ConsiderBatchOptions = ConsiderBatchOptions(),
        statusNote: String? = nil
    ) {
        self.mobs = mobs
        self.defaultCommand = defaultCommand
        self.executeMode = executeMode
        self.enabled = enabled
        self.options = options
        self.statusNote = statusNote
    }
}

/// The persisted slice of the feature's configuration (survives reloads / world
/// reopen — the plugin's `save_state`).
struct ConsiderSettings: Codable, Equatable {
    var defaultCommand = "kill"
    var executeMode = ConsiderExecuteMode.skill
    var enabled = true
    var autoOnEntry = true
    var autoOnCombatEnd = true
    var options = ConsiderBatchOptions()
}

/// Native port of the MUSHclient Consider miniwindow
/// (AardCrowley/Mushclient-Consider): a floating list of the room's mobs with
/// difficulty tiers, click-to-attack, and a `conwall` batch sweep. The pure
/// ``ConsiderModel`` does the parsing/state; this plugin orchestrates — sending
/// `consider all` on room entry / combat end (gated on player state), gagging
/// the consider output, handling `conw…` commands, and publishing a
/// ``ConsiderSnapshot`` for the panel.
///
/// Data source: like the original, the list comes from parsing `consider all`
/// output (Aardwolf has no GMCP room-occupant list). Auto-refresh is driven by
/// the `roomchars` tag feed when it's enabled (re-consider when the occupant set
/// changes), falling back to `room.info` (room change) + the combat-end
/// `char.status` transition. Never fired mid-combat / running / note-writing. The
/// roomchars block is observed only — never gagged (it's the room's `look`
/// display).
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
                + "Auto-refreshes on room entry / combat end (when safe). Click a mob to attack it.",
            commands: [
                .init(syntax: "conw", summary: "Refresh the list now (run `consider all`)."),
                .init(syntax: "conw on|off", summary: "Enable/disable auto-refresh."),
                .init(syntax: "conw cmd <command>", summary: "Set the default attack command (e.g. `kill`)."),
                .init(syntax: "conw mode skill|cast|pro", summary: "How attack targets are formatted."),
                .init(
                    syntax: "conw <n> [command]",
                    summary: "Attack list mob #n (optionally with a command)."
                ),
                .init(syntax: "conwall", summary: "Attack every mob that passes the filters.")
            ]
        )
    }

    /// `char.status.state` values in which it's safe to auto-`consider`: 3
    /// (standing/playing) and 11 (AFK/idle, still in-world) — never login (1),
    /// note-writing (5), running (12), or combat (8). Mirrors AsciiMap.
    private static let playingStates: Set<Int> = [3, 11]

    private var model = ConsiderModel()
    private var settings = ConsiderSettings()

    private var playerState: Int?
    private var playerAlign: Int?
    private var currentZone: String?
    private var currentRoom: Int?
    private var isSafeRoom = false
    private var wasInCombat = false
    private var statusNote: String?
    /// Curated `area → name → keyword` overrides read from S&D's `SnDdb.db`
    /// (empty when S&D isn't installed). Loaded once on connect.
    private var exceptions: [String: [String: String]] = [:]

    // Roomchars-driven refresh (Aardwolf's `{roomchars}` tag block). The block
    // fires on a heartbeat, so we re-consider only when the occupant *set*
    // changes (room entry, a kill, an arrival), not on every block.
    private var inRoomchars = false
    private var roomcharsBuffer: [String] = []
    private var lastRoomSignature: [String]?
    /// Once we've seen a roomchars block, it (not `room.info`) drives refreshes.
    private var sawRoomchars = false
    /// An occupant change arrived while not in a playing state (mid-combat); the
    /// refresh is deferred until we return to a playing state.
    private var pendingConsider = false

    public init() {}

    /// Load S&D's keyword exceptions (read-only) so click/batch targeting uses
    /// the same curated keywords S&D would. No-op when S&D isn't installed.
    public mutating func connect() -> [ScriptEffect] {
        if let url = ConsiderKeyword.defaultDatabaseURL() {
            exceptions = ConsiderKeyword.loadExceptions(from: url)
        }
        return []
    }

    // MARK: - GMCP

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        switch package.lowercased() {
        case "char.status":
            onCharStatus(json)
        case "room.info":
            onRoomInfo(json)
        default:
            []
        }
    }

    private mutating func onCharStatus(_ json: String) -> [ScriptEffect] {
        guard let status = try? JSONDecoder().decode(CharStatus.self, from: Data(json.utf8))
        else { return [] }
        playerAlign = status.align
        let previous = playerState
        playerState = status.state
        if status.state == 8 { wasInCombat = true }

        let nowPlaying = status.state.map(Self.playingStates.contains) ?? false
        guard nowPlaying, previous != status.state else { return [] }

        // A refresh deferred during combat (occupants changed) fires now.
        if pendingConsider {
            pendingConsider = false
            wasInCombat = false
            return settings.enabled ? beginConsiderSequence() : []
        }
        // Combat-end fallback — only when roomchars isn't the driver (otherwise
        // an occupant change already triggered, or will, via the tag block).
        if !sawRoomchars, wasInCombat {
            wasInCombat = false
            if settings.enabled, settings.autoOnCombatEnd { return beginConsiderSequence() }
        }
        return []
    }

    private mutating func onRoomInfo(_ json: String) -> [ScriptEffect] {
        guard let room = try? JSONDecoder().decode(RoomInfo.self, from: Data(json.utf8)) else { return [] }
        let movedRooms = room.num != currentRoom
        currentRoom = room.num
        currentZone = room.zone
        isSafeRoom = room.details?.contains("safe") ?? false

        // Once roomchars drives refreshes, room.info only tracks zone/safe state.
        guard !sawRoomchars, movedRooms, settings.enabled, settings.autoOnEntry else { return [] }
        guard playerState.map(Self.playingStates.contains) ?? false else { return [] }
        return beginConsiderSequence()
    }

    // MARK: - Consider lifecycle

    /// Start a `consider all` capture, or short-circuit with a status note for a
    /// safe room / ignored zone (clearing the list, sending nothing). Mirrors the
    /// plugin's `Send_Consider_Internal`.
    private mutating func beginConsiderSequence() -> [ScriptEffect] {
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
        // `echo nhm` is the end-of-output sentinel: the consider lines stream
        // (gagged), then the server echoes "nhm", which we catch to finalise.
        return [.sendNoEcho("consider all"), .sendNoEcho("echo nhm"), publishEffect()]
    }

    // MARK: - Line ingestion

    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)

        // Aardwolf `{roomchars}…{/roomchars}` block. OBSERVE only — never gag it:
        // the occupant lines are the room's "Also here" display that `look`/entry
        // shows, so suppressing them empties the room. The `{roomchars}` markers
        // themselves are hidden by the display tag layer; we just watch the block
        // to detect occupant changes.
        if trimmed == "{roomchars}" {
            inRoomchars = true
            roomcharsBuffer = []
            return .init()
        }
        if inRoomchars {
            if trimmed == "{/roomchars}" {
                inRoomchars = false
                sawRoomchars = true
                return .init(effects: handleRoomchars(roomcharsBuffer))
            }
            roomcharsBuffer.append(trimmed)
            return .init()
        }

        if model.considering {
            if trimmed == "nhm" {
                model.endConsider()
                return .init(gag: true, effects: [publishEffect()])
            }
            if trimmed == "You see no one here but yourself!" {
                return .init(gag: true)
            }
        }
        let zone = currentZone
        let table = exceptions
        let outcome = model.ingestLine(line.text, zone: zone) {
            ConsiderKeyword.resolve($0, area: zone, exceptions: table)
        }
        switch outcome {
        case .considered:
            return .init(gag: true, effects: [publishEffect()])
        case .mobLeft, .mobArrived, .mobFled, .mobKilled:
            return .init(effects: [publishEffect()])
        case .ignored:
            return .init()
        }
    }

    /// React to a completed roomchars block: re-consider only when the occupant
    /// set changed (the block fires on a heartbeat). An empty room clears the
    /// list; an occupant change while not in a playing state defers to combat-end.
    private mutating func handleRoomchars(_ occupants: [String]) -> [ScriptEffect] {
        guard occupants != lastRoomSignature else { return [] }
        lastRoomSignature = occupants
        if occupants.isEmpty {
            model.clear()
            statusNote = nil
            return [publishEffect()]
        }
        guard settings.enabled, settings.autoOnEntry else { return [] }
        if playerState.map(Self.playingStates.contains) ?? false {
            return beginConsiderSequence()
        }
        pendingConsider = true
        return []
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
        case "on": settings.enabled = true; return configChanged()
        case "off": settings.enabled = false; return configChanged()
        case "cmd":
            if !arg.isEmpty { settings.defaultCommand = arg }
            return configChanged()
        case "mode":
            if let mode = ConsiderExecuteMode(rawValue: arg.lowercased()) { settings.executeMode = mode }
            return configChanged()
        case "auto": return setAuto(tokens)
        case "skip": return setSkip(tokens)
        case "level": return setLevel(tokens)
        default: return [helpNote()]
        }
    }

    private mutating func setLevel(_ tokens: [String]) -> [ScriptEffect] {
        if tokens.count == 2, let lo = Int(tokens[0]), let hi = Int(tokens[1]) {
            settings.options.minLevel = min(lo, hi)
            settings.options.maxLevel = max(lo, hi)
        }
        return configChanged()
    }

    private mutating func setAuto(_ tokens: [String]) -> [ScriptEffect] {
        guard tokens.count == 2 else { return [helpNote()] }
        let on = tokens[1].lowercased() == "on"
        switch tokens[0].lowercased() {
        case "entry": settings.autoOnEntry = on
        case "combat": settings.autoOnCombatEnd = on
        default: return [helpNote()]
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
    private func configChanged() -> [ScriptEffect] {
        [publishEffect(), .persistPluginState(id: metadata.id)]
    }

    private func helpNote() -> ScriptEffect {
        .echo("Consider: conw | conw on/off | conw cmd <command> | conw mode skill/cast/pro | "
            + "conw <n> [command] | conwall")
    }

    // MARK: - Snapshot

    private func snapshot() -> ConsiderSnapshot {
        ConsiderSnapshot(
            mobs: model.mobs,
            defaultCommand: settings.defaultCommand,
            executeMode: settings.executeMode,
            enabled: settings.enabled,
            options: settings.options,
            statusNote: statusNote
        )
    }

    private func publishEffect() -> ScriptEffect {
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
