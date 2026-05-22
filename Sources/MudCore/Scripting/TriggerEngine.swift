import Foundation

/// How a ``Trigger`` matches an incoming line. Each compiles to a cached
/// `NSRegularExpression`. Unlike MUSHclient (which anchors every literal
/// pattern to the whole line and silently drops `?`), the match scope is
/// explicit here.
public enum TriggerPattern: Sendable, Equatable {
    /// Matches anywhere in the line (Mudlet "substring").
    case substring(String)
    /// Matches at the start of the line.
    case beginsWith(String)
    /// The whole line must equal this exactly.
    case exact(String)
    /// MUSHclient-style wildcards, anchored to the whole line: `*` captures
    /// any run (non-greedy), `?` captures a single character. Each `*`/`?`
    /// becomes a numbered capture. (Improves on MUSHclient, where `?` is not
    /// a wildcard.)
    case wildcard(String)
    /// A full regular expression (ICU/`NSRegularExpression` syntax), matched
    /// unanchored. Numbered and `(?<name>…)` captures are supported.
    case regex(String)

    /// The regex source this pattern compiles to.
    func regexSource() -> String {
        switch self {
        case .substring(let text):
            return NSRegularExpression.escapedPattern(for: text)
        case .beginsWith(let text):
            return "^" + NSRegularExpression.escapedPattern(for: text)
        case .exact(let text):
            return "^" + NSRegularExpression.escapedPattern(for: text) + "$"
        case .wildcard(let text):
            var source = "^"
            for character in text {
                switch character {
                case "*": source += "(.*?)"
                case "?": source += "(.)"
                default: source += NSRegularExpression.escapedPattern(for: String(character))
                }
            }
            return source + "$"
        case .regex(let pattern):
            return pattern
        }
    }
}

/// The result of a trigger matching a line: the whole match plus numbered
/// and named captures, with `%`-substitution for send templates.
public struct TriggerMatch: Sendable, Equatable {
    /// The full matched text (`%0`).
    public let whole: String
    /// Numbered captures; index 0 is ``whole``, 1… are the groups (`%1`…).
    /// Unmatched optional groups are empty strings.
    public let captures: [String]
    /// Named captures from `(?<name>…)` groups.
    public let named: [String: String]

    public init(whole: String, captures: [String], named: [String: String] = [:]) {
        self.whole = whole
        self.captures = captures
        self.named = named
    }

    /// Substitute captures into a send template: `%0`–`%9` numbered groups,
    /// `%<name>` named groups, `%%` a literal `%`. Unknown sequences are
    /// passed through verbatim.
    public func expand(_ template: String) -> String {
        var result = ""
        var iterator = template.makeIterator()
        var pending: Character? = iterator.next()
        while let character = pending {
            guard character == "%" else {
                result.append(character)
                pending = iterator.next()
                continue
            }
            switch iterator.next() {
            case "%":
                result.append("%")
            case "<":
                var name = ""
                var next = iterator.next()
                while let value = next, value != ">" {
                    name.append(value)
                    next = iterator.next()
                }
                result.append(named[name] ?? "")
            case let digit? where digit.isNumber:
                let index = Int(String(digit)) ?? 0
                result.append(index < captures.count ? captures[index] : "")
            case let other?:
                result.append("%")
                result.append(other)
            case nil:
                result.append("%")
            }
            pending = iterator.next()
        }
        return result
    }
}

/// A line-matching rule and the response to fire when it matches. A pure
/// value type: matching is decided here, but *executing* the response
/// (sending, running the script, gagging) is the host's job — keeping the
/// engine testable without UI/network/Lua.
public struct Trigger: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var pattern: TriggerPattern
    public var caseSensitive: Bool
    public var enabled: Bool
    /// Lower fires first; ties keep insertion order.
    public var sequence: Int
    /// Optional group for bulk enable/disable.
    public var group: String?
    /// When false, a match stops evaluation of later triggers for this line.
    /// Defaults to true (every matching trigger fires) — avoiding
    /// MUSHclient's loop-aborting `keep_evaluating` footgun.
    public var continueEvaluation: Bool
    /// Remove the trigger after it fires once (a temporary trigger).
    public var oneShot: Bool
    /// Omit the matched line from the output.
    public var gag: Bool
    /// Text to send to the MUD on match, with `%`-substitution.
    public var sendText: String?
    /// Lua to run on match (the host provides the captures).
    public var script: String?

    public init(
        id: UUID = UUID(),
        pattern: TriggerPattern,
        caseSensitive: Bool = false,
        enabled: Bool = true,
        sequence: Int = 100,
        group: String? = nil,
        continueEvaluation: Bool = true,
        oneShot: Bool = false,
        gag: Bool = false,
        sendText: String? = nil,
        script: String? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.enabled = enabled
        self.sequence = sequence
        self.group = group
        self.continueEvaluation = continueEvaluation
        self.oneShot = oneShot
        self.gag = gag
        self.sendText = sendText
        self.script = script
    }
}

/// One trigger that fired on a line, with its expanded send text and the
/// captures (for the script). The host applies these.
public struct TriggerFiring: Sendable, Equatable {
    public let triggerID: UUID
    public let match: TriggerMatch
    /// `sendText` with captures substituted in (if any).
    public let send: String?
    /// The trigger's script (raw), if any.
    public let script: String?
    /// Whether the line should be omitted from output.
    public let gag: Bool
}

/// Matches incoming lines against a sorted set of triggers (PLAN.md §8.6).
///
/// Evaluation order is explicit: triggers run in ascending ``Trigger/sequence``
/// (ties in insertion order). A match fires the trigger; evaluation continues
/// to later triggers unless the matched trigger sets
/// ``Trigger/continueEvaluation`` to false. A non-match never stops the loop
/// (unlike MUSHclient). One-shot triggers are removed after they fire.
public struct TriggerEngine {
    private struct Compiled {
        let regex: NSRegularExpression
        let names: [String]
    }

    public enum TriggerError: Error, Equatable {
        case invalidPattern(String)
    }

    private var triggers: [Trigger] = []
    private var compiled: [UUID: Compiled] = [:]
    private var disabledGroups: Set<String> = []

    public init() {}

    /// All triggers, in evaluation order.
    public var allTriggers: [Trigger] {
        triggers
    }

    /// Add a trigger (compiling its pattern). Throws on an invalid regex.
    public mutating func add(_ trigger: Trigger) throws {
        compiled[trigger.id] = try Self.compile(trigger)
        let index = triggers.firstIndex { $0.sequence > trigger.sequence } ?? triggers.count
        triggers.insert(trigger, at: index)
    }

    /// Remove a trigger by id.
    public mutating func remove(id: UUID) {
        triggers.removeAll { $0.id == id }
        compiled[id] = nil
    }

    /// Enable or disable a single trigger.
    public mutating func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = triggers.firstIndex(where: { $0.id == id }) else { return }
        triggers[index].enabled = enabled
    }

    /// Enable or disable every trigger in a group.
    public mutating func setGroupEnabled(_ enabled: Bool, group: String) {
        if enabled { disabledGroups.remove(group) } else { disabledGroups.insert(group) }
    }

    /// Test `line` against every active trigger in order, returning the
    /// firings. One-shot triggers that fire are removed.
    public mutating func process(_ line: String) -> [TriggerFiring] {
        var firings: [TriggerFiring] = []
        var oneShotsToRemove: [UUID] = []

        for trigger in triggers {
            guard trigger.enabled else { continue }
            if let group = trigger.group, disabledGroups.contains(group) { continue }
            guard let compiled = compiled[trigger.id],
                  let match = Self.match(line, with: compiled)
            else { continue }

            firings.append(TriggerFiring(
                triggerID: trigger.id,
                match: match,
                send: trigger.sendText.map { match.expand($0) },
                script: trigger.script,
                gag: trigger.gag
            ))
            if trigger.oneShot { oneShotsToRemove.append(trigger.id) }
            if !trigger.continueEvaluation { break }
        }

        for id in oneShotsToRemove {
            remove(id: id)
        }
        return firings
    }

    // MARK: - Private

    private static func compile(_ trigger: Trigger) throws -> Compiled {
        let source = trigger.pattern.regexSource()
        var options: NSRegularExpression.Options = []
        if !trigger.caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: source, options: options) else {
            throw TriggerError.invalidPattern(source)
        }
        return Compiled(regex: regex, names: capturedGroupNames(in: source))
    }

    private static func match(_ line: String, with compiled: Compiled) -> TriggerMatch? {
        let text = line as NSString
        let range = NSRange(location: 0, length: text.length)
        guard let result = compiled.regex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }
        var captures: [String] = []
        for index in 0..<result.numberOfRanges {
            let groupRange = result.range(at: index)
            captures.append(groupRange.location == NSNotFound ? "" : text.substring(with: groupRange))
        }
        var named: [String: String] = [:]
        for name in compiled.names {
            let namedRange = result.range(withName: name)
            named[name] = namedRange.location == NSNotFound ? "" : text.substring(with: namedRange)
        }
        return TriggerMatch(whole: captures.first ?? "", captures: captures, named: named)
    }

    /// Extract the names of `(?<name>…)` capture groups from a regex source.
    private static let namePattern = try? NSRegularExpression(
        pattern: #"\(\?P?<([A-Za-z_][A-Za-z0-9_]*)>"#
    )

    private static func capturedGroupNames(in source: String) -> [String] {
        guard let namePattern else { return [] }
        let text = source as NSString
        let range = NSRange(location: 0, length: text.length)
        return namePattern.matches(in: source, range: range).map {
            text.substring(with: $0.range(at: 1))
        }
    }
}
