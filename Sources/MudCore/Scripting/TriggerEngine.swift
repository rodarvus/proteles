import Foundation

/// How a ``Trigger`` matches an incoming line. Each compiles to a cached
/// `NSRegularExpression`. Unlike MUSHclient (which anchors every literal
/// pattern to the whole line and silently drops `?`), the match scope is
/// explicit here.
public enum TriggerPattern: Sendable, Equatable, Codable {
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

    /// The match text as authored (the wildcard/regex/literal source, before
    /// any conversion). This is the string MUSHclient stores as the trigger's
    /// "match" and uses to order same-sequence triggers — see ``TriggerEngine``.
    var matchText: String {
        switch self {
        case .substring(let text), .beginsWith(let text), .exact(let text),
             .wildcard(let text), .regex(let text):
            text
        }
    }

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
    /// Where ``whole`` sits in the matched line, in UTF-16 code units (the
    /// `StyledRun` index space) — so a `.matchedText` highlight can restyle
    /// exactly the matched span. Nil for matches built without one.
    public let utf16Range: Range<Int>?

    public init(
        whole: String,
        captures: [String],
        named: [String: String] = [:],
        utf16Range: Range<Int>? = nil
    ) {
        self.whole = whole
        self.captures = captures
        self.named = named
        self.utf16Range = utf16Range
    }

    /// Substitute captures into a send template: `%0`–`%9` numbered groups,
    /// `%<name>` named groups, `%%` a literal `%`. Unknown sequences are
    /// passed through verbatim.
    public func expand(_ template: String) -> String {
        expand(template, escape: { $0 })
    }

    /// Like ``expand(_:)`` but escapes each substituted capture for embedding in
    /// a Lua **string literal** — MUSHclient plugins build script bodies like
    /// `fn("%1")` and run them as Lua (trigger/alias send-to-script). A raw
    /// capture containing `\`, `"`, or a newline would otherwise produce invalid
    /// Lua (e.g. dinv's statBonus closing marker `{ \dinv … }` → `"\d…"`, which
    /// Lua 5.1 rejects as a bad escape — so the handler never ran and dinv's
    /// catch-all `^(.*)$` gag stayed enabled, suppressing all output).
    public func expandForScript(_ template: String) -> String {
        expand(template, escape: Self.luaStringEscape)
    }

    private func expand(_ template: String, escape: (String) -> String) -> String {
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
                result.append(escape(named[name] ?? ""))
            case let digit? where digit.isNumber:
                let index = Int(String(digit)) ?? 0
                result.append(escape(index < captures.count ? captures[index] : ""))
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

    /// Escape a string for safe embedding inside a double-quoted Lua literal.
    static func luaStringEscape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        return out
    }
}

/// Where a trigger's expanded ``Trigger/sendText`` goes (D-105). The
/// output-side counterpart of ``AliasTarget``, trimmed to the subset an
/// Aardwolf player uses (MUSHclient's `eSendTo` 0/10/2): there is no
/// `.script` case because ``Trigger/script`` is its own field.
public enum TriggerTarget: String, Sendable, Equatable, Codable, CaseIterable {
    /// Send the expansion to the MUD (`eSendToWorld`). The default.
    case world
    /// Re-feed the expansion through the input pipeline — aliases and
    /// `;`-stacking apply (`eSendToExecute`).
    case execute
    /// Echo the expansion to the local output, sending nothing
    /// (`eSendToOutput`).
    case output
}

/// A line-matching rule and the response to fire when it matches. A pure
/// value type: matching is decided here, but *executing* the response
/// (sending, running the script, gagging) is the host's job — keeping the
/// engine testable without UI/network/Lua.
public struct Trigger: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID
    /// Optional name (MUSHclient triggers are named; used by the plugin
    /// loader and `EnableTrigger`). Not used by matching.
    public var name: String?
    public var pattern: TriggerPattern
    public var caseSensitive: Bool
    public var enabled: Bool
    /// Lower fires first; ties run in match-text byte order (MUSHclient's
    /// `CompareTrigger` tiebreak — see ``TriggerEngine``).
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
    /// Text to send on match, with `%`-substitution; ``sendTo`` says where.
    public var sendText: String?
    /// Where the expanded ``sendText`` goes (D-105). Defaults to the MUD.
    public var sendTo: TriggerTarget
    /// Lua to run on match (the host provides the captures).
    public var script: String?
    /// Restyle the line on match (D-105) — nil leaves the MUD's colours alone.
    public var highlight: TriggerHighlight?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        pattern: TriggerPattern,
        caseSensitive: Bool = false,
        enabled: Bool = true,
        sequence: Int = 100,
        group: String? = nil,
        continueEvaluation: Bool = true,
        oneShot: Bool = false,
        gag: Bool = false,
        sendText: String? = nil,
        sendTo: TriggerTarget = .world,
        script: String? = nil,
        highlight: TriggerHighlight? = nil
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.enabled = enabled
        self.sequence = sequence
        self.group = group
        self.continueEvaluation = continueEvaluation
        self.oneShot = oneShot
        self.gag = gag
        self.sendText = sendText
        self.sendTo = sendTo
        self.script = script
        self.highlight = highlight
    }

    /// Tolerant decode: ``sendTo`` (D-105) and ``highlight`` are additions —
    /// triggers stored before them decode with the old behaviour (send to
    /// the MUD, no restyle).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        pattern = try container.decode(TriggerPattern.self, forKey: .pattern)
        caseSensitive = try container.decode(Bool.self, forKey: .caseSensitive)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        sequence = try container.decode(Int.self, forKey: .sequence)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        continueEvaluation = try container.decode(Bool.self, forKey: .continueEvaluation)
        oneShot = try container.decode(Bool.self, forKey: .oneShot)
        gag = try container.decode(Bool.self, forKey: .gag)
        sendText = try container.decodeIfPresent(String.self, forKey: .sendText)
        sendTo = try container.decodeIfPresent(TriggerTarget.self, forKey: .sendTo) ?? .world
        script = try container.decodeIfPresent(String.self, forKey: .script)
        highlight = try container.decodeIfPresent(TriggerHighlight.self, forKey: .highlight)
    }
}

/// One trigger that fired on a line, with its expanded send text and the
/// captures (for the script). The host applies these.
public struct TriggerFiring: Sendable, Equatable {
    public let triggerID: UUID
    public let match: TriggerMatch
    /// `sendText` with captures substituted in (if any).
    public let send: String?
    /// Where ``send`` goes (D-105): the MUD, the input pipeline, or a local echo.
    public let target: TriggerTarget
    /// The trigger's script (raw), if any.
    public let script: String?
    /// Whether the line should be omitted from output.
    public let gag: Bool
    /// Restyle to apply to the displayed line (D-105), if any.
    public let highlight: TriggerHighlight?
}

/// Matches incoming lines against a sorted set of triggers (PLAN.md §8.6).
///
/// Evaluation order is explicit: triggers run in ascending ``Trigger/sequence``,
/// ties in ascending **match text** (byte order) — MUSHclient's `CompareTrigger`
/// tiebreak, which plugins are written against. A real plugin arms a catch-all
/// `^(?P<x>.+)$` between `{roomchars}`…`{/roomchars}` markers and relies on the
/// end marker's handler running *first* on the `{/roomchars}` line (both match
/// it at the same sequence; `*{/roomchars}*` sorts before `^…`) to clear a
/// "scanning" flag the catch-all's handler gates on — insertion-order ties made
/// the catch-all capture the tag itself as a mob name in empty rooms. Exact
/// duplicates keep insertion order. A match fires the trigger; evaluation
/// continues to later triggers unless the matched trigger sets
/// ``Trigger/continueEvaluation`` to false. A non-match never stops the loop
/// (unlike MUSHclient). One-shot triggers are removed after they fire.
public struct TriggerEngine {
    public enum TriggerError: Error, Equatable {
        case invalidPattern(String)
    }

    private var triggers: [Trigger] = []
    private var matchers: [UUID: PatternMatcher] = [:]

    public init() {}

    /// All triggers, in evaluation order.
    public var allTriggers: [Trigger] {
        triggers
    }

    /// Add a trigger (compiling its pattern). Throws on an invalid regex.
    public mutating func add(_ trigger: Trigger) throws {
        do {
            matchers[trigger.id] = try PatternMatcher(
                pattern: trigger.pattern,
                caseSensitive: trigger.caseSensitive
            )
        } catch PatternMatcher.MatchError.invalidPattern(let source) {
            throw TriggerError.invalidPattern(source)
        }
        let index = triggers.firstIndex { existing in
            existing.sequence > trigger.sequence ||
                (existing.sequence == trigger.sequence &&
                    matchTextOrder(trigger.pattern.matchText, precedes: existing.pattern.matchText))
        } ?? triggers.count
        triggers.insert(trigger, at: index)
    }

    /// Strict byte-order "less than" (MUSHclient compares the match CStrings
    /// with `_tcscmp`) — NOT Unicode-canonical `String` comparison, which can
    /// disagree with byte order outside ASCII.
    private func matchTextOrder(_ lhs: String, precedes rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Remove a trigger by id.
    public mutating func remove(id: UUID) {
        triggers.removeAll { $0.id == id }
        matchers[id] = nil
    }

    /// Enable or disable a single trigger.
    public mutating func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = triggers.firstIndex(where: { $0.id == id }) else { return }
        triggers[index].enabled = enabled
    }

    /// Enable or disable every trigger in a group — MUSHclient semantics: it
    /// bulk-sets each member's individual `enabled` flag (it is *not* a separate
    /// gate). So a later `EnableTrigger(name, true)` re-arms one member even
    /// after its group was disabled — which S&D relies on (it disables the
    /// `trg_campaign` group on cp-complete, then re-enables the entry trigger
    /// for the next campaign).
    public mutating func setGroupEnabled(_ enabled: Bool, group: String) {
        for index in triggers.indices where triggers[index].group == group {
            triggers[index].enabled = enabled
        }
    }

    /// Test `line` against every active trigger in order, returning the
    /// firings. One-shot triggers that fire are removed.
    public mutating func process(_ line: String) -> [TriggerFiring] {
        var firings: [TriggerFiring] = []
        var oneShotsToRemove: [UUID] = []

        for trigger in triggers {
            guard trigger.enabled else { continue }
            guard let match = matchers[trigger.id]?.match(line) else { continue }

            firings.append(TriggerFiring(
                triggerID: trigger.id,
                match: match,
                send: trigger.sendText.map { match.expand($0) },
                target: trigger.sendTo,
                script: trigger.script,
                gag: trigger.gag,
                highlight: trigger.highlight
            ))
            if trigger.oneShot { oneShotsToRemove.append(trigger.id) }
            if !trigger.continueEvaluation { break }
        }

        for id in oneShotsToRemove {
            remove(id: id)
        }
        return firings
    }
}
