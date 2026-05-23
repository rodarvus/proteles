import Foundation

/// Native port of Aardwolf's `aard_vital_shortcuts` (Fiendish): type
/// `hp`/`mn`/`mv`/`vitals` to print colour-coded vital percentages — your
/// own, a grouped member's (`hp fiendish`), or everyone under a threshold
/// (`vitals below 40`).
///
/// A value-type reducer on the native-plugin host: it caches the relevant
/// GMCP packages in ``onGMCP(package:json:)`` and renders coloured output in
/// ``handleCommand(_:)`` via the multi-colour ``ScriptEffect/colourNote(_:)``
/// primitive. No miniwindows, no Lua — the whole thing is unit-testable.
public struct VitalShortcuts: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.vitalshortcuts",
        name: "Vital Shortcuts",
        author: "Proteles (after Fiendish)",
        version: "1.0",
        summary: "Type hp/mn/mv/vitals to print colour-coded vital percentages "
            + "(yours or a group member's)."
    )

    // Cached GMCP snapshot, refreshed by onGMCP.
    private var vitals: CharVitals?
    private var maxStats: CharMaxStats?
    private var charName: String?
    private var group: GroupInfo?
    /// True while writing an in-game note (`char.status.state == 5`); the
    /// commands then pass through so they reach the note unmodified.
    private var noteMode = false

    public init() {}

    // MARK: - GMCP

    private struct StatusState: Decodable { let state: Int? }

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        let data = Data(json.utf8)
        switch package.lowercased() {
        case "char.vitals": vitals = try? JSONDecoder().decode(CharVitals.self, from: data)
        case "char.maxstats": maxStats = try? JSONDecoder().decode(CharMaxStats.self, from: data)
        case "char.base": charName = (try? JSONDecoder().decode(CharBase.self, from: data))?.name
        case "char.status":
            noteMode = (try? JSONDecoder().decode(StatusState.self, from: data))?.state == 5
        case "group": group = try? JSONDecoder().decode(GroupInfo.self, from: data)
        default: break
        }
        return []
    }

    // MARK: - Commands

    public func handleCommand(_ input: String) -> [ScriptEffect]? {
        let words = input.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }

        if words == ["vitals", "help"] { return help() }
        // While note-writing, let the command through untouched.
        if noteMode, isOwnedCommand(first) { return nil }

        if let stat = Self.stat(for: first) {
            return route(stat: stat, rest: Array(words.dropFirst()))
        }
        if first == "vitals" {
            return routeAll(rest: Array(words.dropFirst()))
        }
        return nil
    }

    /// Whether `word` is a verb this plugin owns (so note-mode passthrough
    /// only suppresses our own commands, not arbitrary input).
    private func isOwnedCommand(_ word: String) -> Bool {
        word == "vitals" || Self.stat(for: word) != nil
    }

    private func route(stat: Stat, rest: [String]) -> [ScriptEffect]? {
        switch rest.count {
        case 0:
            [showOne(stat: stat, target: "")]
        case 1:
            [showOne(stat: stat, target: rest[0])]
        case 2 where rest[0] == "below":
            showBelow(stat: stat, percent: Int(rest[1]))
        default:
            nil
        }
    }

    private func routeAll(rest: [String]) -> [ScriptEffect]? {
        switch rest.count {
        case 0:
            return Stat.allCases.map { showOne(stat: $0, target: "") }
        case 1:
            return Stat.allCases.map { showOne(stat: $0, target: rest[0]) }
        case 2 where rest[0] == "below":
            guard let percent = Int(rest[1]) else { return nil }
            return Stat.allCases.flatMap { showBelow(stat: $0, percent: percent) ?? [] }
        default:
            return nil
        }
    }

    // MARK: - Rendering

    /// One stat for the player or a named group member.
    private func showOne(stat: Stat, target: String) -> ScriptEffect {
        if target.isEmpty || target.caseInsensitiveCompare(charName ?? "") == .orderedSame {
            guard let current = vitals?[stat], let max = maxStats?[stat], max > 0 else {
                return Self.line(label: stat.selfLabel, percent: nil)
            }
            return Self.line(label: stat.selfLabel, percent: percentage(current, max))
        }
        guard let member = member(matching: target),
              let current = member.info?[stat], let max = member.info?[max: stat], max > 0
        else {
            return Self.notice("You don't know vitals for \(target.capitalizingFirst).")
        }
        return Self.line(label: "\(member.name) \(stat.label)", percent: percentage(current, max))
    }

    /// You or any group member below `percent` for one stat.
    private func showBelow(stat: Stat, percent: Int?) -> [ScriptEffect]? {
        guard let percent else { return nil }
        var results: [ScriptEffect] = []
        if let members = group?.members, !members.isEmpty {
            for member in members {
                if let current = member.info?[stat], let max = member.info?[max: stat], max > 0 {
                    let pct = percentage(current, max)
                    if pct < percent {
                        results.append(Self.line(label: "\(member.name) \(stat.label)", percent: pct))
                    }
                }
            }
        } else if let current = vitals?[stat], let max = maxStats?[stat], max > 0 {
            let pct = percentage(current, max)
            if pct < percent { results.append(Self.line(label: stat.selfLabel, percent: pct)) }
        }
        if results.isEmpty {
            results.append(Self.notice("No one found with \(stat.label) below \(percent)%"))
        }
        return results
    }

    private func member(matching target: String) -> GroupInfo.Member? {
        group?.members?.first { $0.name.lowercased().hasPrefix(target.lowercased()) }
    }

    private func percentage(_ current: Int, _ max: Int) -> Int {
        current * 100 / max
    }

    // MARK: - Output helpers

    /// `Label: NN%` with the number coloured by threshold and the rest in
    /// silver. A `nil` percent means the data isn't available yet.
    private static func line(label: String, percent: Int?) -> ScriptEffect {
        guard let percent else { return notice("\(label): not available") }
        return .colourNote([
            NoteSegment(text: "\(label): ", foreground: colour("silver")),
            NoteSegment(text: "\(percent)", foreground: thresholdColour(percent)),
            NoteSegment(text: "%", foreground: colour("silver"))
        ])
    }

    private static func notice(_ text: String) -> ScriptEffect {
        .colourNote([NoteSegment(text: text, foreground: colour("silver"))])
    }

    private static func thresholdColour(_ percent: Int) -> String {
        if percent <= 33 { return colour("red") }
        if percent <= 66 { return colour("yellow") }
        return colour("lightgreen")
    }

    /// MUSHclient/HTML colour names → `#RRGGBB` (the renderer resolves hex).
    private static func colour(_ name: String) -> String {
        let palette: [String: String] = [
            "silver": "#C0C0C0", "lightgreen": "#90EE90", "red": "#FF4040",
            "yellow": "#FFFF40", "plum": "#DDA0DD", "paleturquoise": "#AFEEEE",
            "khaki": "#F0E68C"
        ]
        return palette[name] ?? name
    }

    private func help() -> [ScriptEffect] {
        func tip(_ command: String, _ description: String) -> ScriptEffect {
            .colourNote([
                NoteSegment(text: "  \(command)", foreground: Self.colour("khaki")),
                NoteSegment(text: " — \(description)", foreground: Self.colour("paleturquoise"))
            ])
        }
        return [
            .colourNote([NoteSegment(text: "Vital Shortcuts", foreground: Self.colour("plum"))]),
            tip("hp / hit", "your hitpoint percentage"),
            tip("mn / mana", "your mana percentage"),
            tip("mv / moves", "your moves percentage"),
            tip("vitals", "all three"),
            tip("hp fiendish", "a grouped member's stat"),
            tip("vitals below 40", "you or anyone in the group under N%")
        ]
    }

    // MARK: - Stat

    fileprivate enum Stat: CaseIterable {
        case hp, mana, moves

        /// Lowercase noun used in group-member labels.
        var label: String {
            switch self {
            case .hp: "hitpoints"
            case .mana: "mana"
            case .moves: "moves"
            }
        }

        /// Capitalised noun used when reporting your own stat.
        var selfLabel: String {
            label.capitalizingFirst
        }
    }

    private static func stat(for word: String) -> Stat? {
        switch word {
        case "hp", "hit": .hp
        case "mn", "mana": .mana
        case "mv", "moves": .moves
        default: nil
        }
    }
}

// MARK: - GMCP field access by stat

private extension CharVitals {
    subscript(stat: VitalShortcuts.Stat) -> Int {
        switch stat {
        case .hp: hp
        case .mana: mana
        case .moves: moves
        }
    }
}

private extension CharMaxStats {
    subscript(stat: VitalShortcuts.Stat) -> Int {
        switch stat {
        case .hp: maxhp
        case .mana: maxmana
        case .moves: maxmoves
        }
    }
}

private extension GroupInfo.Member.Info {
    /// Current value for `stat` (group members send strings).
    subscript(stat: VitalShortcuts.Stat) -> Int? {
        switch stat {
        case .hp: hp.flatMap { Int($0) }
        case .mana: mn.flatMap { Int($0) }
        case .moves: mv.flatMap { Int($0) }
        }
    }

    /// Maximum value for `stat`.
    subscript(max stat: VitalShortcuts.Stat) -> Int? {
        switch stat {
        case .hp: mhp.flatMap { Int($0) }
        case .mana: mmn.flatMap { Int($0) }
        case .moves: mmv.flatMap { Int($0) }
        }
    }
}

private extension String {
    /// Uppercase the first character, leaving the rest unchanged.
    var capitalizingFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
