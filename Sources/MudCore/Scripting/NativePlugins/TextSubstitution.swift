import Foundation

/// Native port of Aardwolf's `aard_text_substitution` (Fiendish): the
/// `#sub`/`#gag` engine. Replace or drop text in the output stream, with
/// `#regex`/`#alone`/`#nocase` flags, preserving per-segment colour. Rules
/// persist per world.
///
/// A value-type reducer: ``onLine(_:)`` runs each line through a
/// ``SubstitutionEngine``; ``handleCommand(_:)`` edits the rule set and
/// emits ``ScriptEffect/persistPluginState(id:)`` so the host saves it.
public struct TextSubstitution: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.textsubstitution",
        name: "Text Substitution",
        author: "Proteles (after Fiendish)",
        version: "1.0",
        summary: "Replace or gag text in the output stream with #sub / #gag (colour preserved)."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Rewrite or hide lines of output. Replacements keep the original "
                + "colour. Flags: #regex (pattern is a regular expression), #alone "
                + "(whole words only), #nocase (case-insensitive). Rules persist per world.",
            commands: [
                .init(syntax: "#sub {A} {B}", summary: "Replace text A with B"),
                .init(syntax: "#gag {A}", summary: "Hide lines containing A"),
                .init(syntax: "#subs", summary: "List substitutions"),
                .init(syntax: "#gags", summary: "List gags"),
                .init(syntax: "#unsub #N", summary: "Remove substitution number N"),
                .init(syntax: "#ungag #N", summary: "Remove gag number N"),
                .init(syntax: "#sub help", summary: "Show usage details")
            ]
        )
    }

    private var engine = SubstitutionEngine()

    public init() {}

    // MARK: - Persistence

    public var persistentState: Data? {
        try? JSONEncoder().encode(engine.rules)
    }

    public mutating func restore(from data: Data) {
        if let rules = try? JSONDecoder().decode([SubstitutionRule].self, from: data) {
            engine.setRules(rules)
        }
    }

    // MARK: - Output

    public func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        switch engine.apply(to: line) {
        case .unchanged: .init()
        case .gag: .init(gag: true)
        case .replace(let replacement): .init(replacement: replacement)
        }
    }

    // MARK: - Commands

    public mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let split = trimmed.split(separator: " ", maxSplits: 1)
        guard let head = split.first.map({ $0.lowercased() }) else { return nil }
        let rest = split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespaces) : ""

        switch head {
        case "#sub", "#subs":
            if rest.isEmpty { return list(.substitute) }
            if rest.lowercased() == "help" { return helpOutput() }
            return addSubstitution(rest)
        case "#gag", "#gags":
            if rest.isEmpty { return list(.gag) }
            return addGag(rest)
        case "#unsub":
            return remove(.substitute, rest)
        case "#ungag":
            return remove(.gag, rest)
        default:
            return nil
        }
    }

    // MARK: - Command handlers

    private mutating func addSubstitution(_ rest: String) -> [ScriptEffect] {
        guard let groups = Self.capture(#"^\{(.*?)\}\s*\{(.*)\}\s*(.*)$"#, rest) else {
            return [Self.note("Usage: #sub {A} {B} [#regex] [#alone] [#nocase]")]
        }
        let flags = Self.flags(groups[2])
        engine.add(SubstitutionRule(
            kind: .substitute,
            pattern: groups[0],
            replacement: groups[1],
            regex: flags.regex,
            wholeWord: flags.alone,
            caseSensitive: !flags.nocase
        ))
        return [
            .persistPluginState(id: metadata.id),
            Self.note("Added substitution: '\(groups[0])' → '\(groups[1])'.")
        ]
    }

    private mutating func addGag(_ rest: String) -> [ScriptEffect] {
        guard let groups = Self.capture(#"^\{(.*?)\}\s*(.*)$"#, rest) else {
            return [Self.note("Usage: #gag {A} [#regex] [#alone] [#nocase]")]
        }
        let flags = Self.flags(groups[1])
        engine.add(SubstitutionRule(
            kind: .gag,
            pattern: groups[0],
            regex: flags.regex,
            wholeWord: flags.alone,
            caseSensitive: !flags.nocase
        ))
        return [.persistPluginState(id: metadata.id), Self.note("Added gag: '\(groups[0])'.")]
    }

    private mutating func remove(_ kind: SubstitutionRule.Kind, _ rest: String) -> [ScriptEffect] {
        let label = kind == .substitute ? "substitution" : "gag"
        let rules = kind == .substitute ? engine.substitutions : engine.gags
        guard let number = Int(rest.filter(\.isNumber)), number >= 1, number <= rules.count else {
            return [Self.note("No \(label) #\(rest.filter(\.isNumber)).")]
        }
        engine.remove(id: rules[number - 1].id)
        return [.persistPluginState(id: metadata.id), Self.note("Removed \(label) #\(number).")]
    }

    private func list(_ kind: SubstitutionRule.Kind) -> [ScriptEffect] {
        let rules = kind == .substitute ? engine.substitutions : engine.gags
        let label = kind == .substitute ? "Substitutions" : "Gags"
        guard !rules.isEmpty else { return [Self.note("No \(label.lowercased()).")] }
        var output: [ScriptEffect] = [Self.note("\(label):")]
        for (index, rule) in rules.enumerated() {
            let body = kind == .substitute
                ? "{\(rule.pattern)} → {\(rule.replacement)}"
                : "{\(rule.pattern)}"
            output.append(Self.note("  #\(index + 1)  \(body)\(Self.flagLabel(rule))"))
        }
        return output
    }

    private func helpOutput() -> [ScriptEffect] {
        help.commands.map { Self.note("  \($0.syntax)  —  \($0.summary)") }
    }

    // MARK: - Parsing helpers

    private struct Flags {
        let regex: Bool
        let alone: Bool
        let nocase: Bool
    }

    private static func flags(_ tail: String) -> Flags {
        let lower = tail.lowercased()
        return Flags(
            regex: lower.contains("#regex"),
            alone: lower.contains("#alone"),
            nocase: lower.contains("#nocase")
        )
    }

    private static func flagLabel(_ rule: SubstitutionRule) -> String {
        var parts: [String] = []
        if rule.regex { parts.append("#regex") }
        if rule.wholeWord { parts.append("#alone") }
        if !rule.caseSensitive { parts.append("#nocase") }
        return parts.isEmpty ? "" : "  [\(parts.joined(separator: " "))]"
    }

    /// Capture groups for `pattern` against `text`, or nil if it doesn't match.
    private static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : nsText.substring(with: range)
        }
    }

    private static func note(_ text: String) -> ScriptEffect {
        .colourNote([NoteSegment(text: text, foreground: "#C0C0C0")])
    }
}
