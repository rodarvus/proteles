import Foundation

/// Where an alias's expanded text goes (modelled on MUSHclient's `iSendTo`,
/// trimmed to what matters for v1).
public enum AliasTarget: Sendable, Equatable {
    /// Send the expansion raw to the MUD (`eSendToWorld`). The default.
    case world
    /// Re-feed the expansion through alias matching (`eSendToExecute`),
    /// guarded by a recursion-depth limit.
    case execute
    /// Treat the expansion as Lua and run it (`eSendToScript`).
    case script
    /// Echo the expansion to the local output, sending nothing
    /// (`eSendToOutput`).
    case output
}

/// An input-line rule: matches what the user types and rewrites it before
/// it's sent. The input-side counterpart to ``Trigger``. A pure value type —
/// matching here, action execution in the host.
public struct Alias: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var pattern: TriggerPattern
    public var caseSensitive: Bool
    public var enabled: Bool
    /// Lower fires first; ties keep insertion order.
    public var sequence: Int
    public var group: String?
    /// When true, later aliases are still tested after this one matches.
    /// Defaults to false — typed input maps to one intent (matching
    /// MUSHclient's alias default, the opposite of triggers).
    public var keepEvaluating: Bool
    public var oneShot: Bool
    /// The expansion template (`%`-substituted from captures). Interpreted
    /// per ``sendTo``: a command for `.world`/`.execute`, text for `.output`,
    /// or Lua for `.script`.
    public var sendText: String?
    public var sendTo: AliasTarget

    public init(
        id: UUID = UUID(),
        pattern: TriggerPattern,
        caseSensitive: Bool = false,
        enabled: Bool = true,
        sequence: Int = 100,
        group: String? = nil,
        keepEvaluating: Bool = false,
        oneShot: Bool = false,
        sendText: String? = nil,
        sendTo: AliasTarget = .world
    ) {
        self.id = id
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.enabled = enabled
        self.sequence = sequence
        self.group = group
        self.keepEvaluating = keepEvaluating
        self.oneShot = oneShot
        self.sendText = sendText
        self.sendTo = sendTo
    }
}

/// One alias that matched the input, with its expanded text and target.
public struct AliasFiring: Sendable, Equatable {
    public let aliasID: UUID
    public let match: TriggerMatch
    /// `sendText` with captures substituted in (if any).
    public let send: String?
    public let target: AliasTarget
}

/// Matches typed input against a sorted set of aliases (PLAN.md §8.6).
///
/// Like ``TriggerEngine`` this is pure matching: it returns ``AliasFiring``s
/// and the host orchestrates the actions (send / echo / script / re-expand).
/// Evaluation is ascending ``Alias/sequence`` (stable on ties); a match stops
/// later aliases unless ``Alias/keepEvaluating`` is set. The host treats *no*
/// firings as "send the line verbatim".
public struct AliasEngine {
    public enum AliasError: Error, Equatable {
        case invalidPattern(String)
    }

    private var aliases: [Alias] = []
    private var matchers: [UUID: PatternMatcher] = [:]
    private var disabledGroups: Set<String> = []

    public init() {}

    public var allAliases: [Alias] {
        aliases
    }

    public mutating func add(_ alias: Alias) throws {
        do {
            matchers[alias.id] = try PatternMatcher(
                pattern: alias.pattern,
                caseSensitive: alias.caseSensitive
            )
        } catch PatternMatcher.MatchError.invalidPattern(let source) {
            throw AliasError.invalidPattern(source)
        }
        let index = aliases.firstIndex { $0.sequence > alias.sequence } ?? aliases.count
        aliases.insert(alias, at: index)
    }

    public mutating func remove(id: UUID) {
        aliases.removeAll { $0.id == id }
        matchers[id] = nil
    }

    public mutating func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = aliases.firstIndex(where: { $0.id == id }) else { return }
        aliases[index].enabled = enabled
    }

    public mutating func setGroupEnabled(_ enabled: Bool, group: String) {
        if enabled { disabledGroups.remove(group) } else { disabledGroups.insert(group) }
    }

    /// Match `input` against the aliases in order. Empty result means no
    /// alias matched (the host should send the line as typed).
    public mutating func match(_ input: String) -> [AliasFiring] {
        var firings: [AliasFiring] = []
        var oneShotsToRemove: [UUID] = []

        for alias in aliases {
            guard alias.enabled else { continue }
            if let group = alias.group, disabledGroups.contains(group) { continue }
            guard let match = matchers[alias.id]?.match(input) else { continue }

            firings.append(AliasFiring(
                aliasID: alias.id,
                match: match,
                send: alias.sendText.map { match.expand($0) },
                target: alias.sendTo
            ))
            if alias.oneShot { oneShotsToRemove.append(alias.id) }
            if !alias.keepEvaluating { break }
        }

        for id in oneShotsToRemove {
            remove(id: id)
        }
        return firings
    }
}
