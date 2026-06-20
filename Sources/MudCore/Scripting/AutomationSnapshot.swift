import Foundation

/// A read-only mirror of the live triggers/aliases/timers, projected by
/// ``ScriptEngine`` into the ``LuaRuntime`` so the synchronous MUSHclient
/// introspection world-API (`GetTriggerInfo`/`GetTimerInfo`/`GetAliasInfo`,
/// `GetTriggerList`/`GetTimerList`/`GetAliasList`, `GetPluginTriggerList`) can
/// answer without hopping the actor boundary — the same pattern
/// ``OutputLineBuffer`` uses to back `GetLineCount`/`GetLineInfo`.
///
/// These functions are broadly used by MUSHclient plugin developers to render
/// and reflect on their own automation (e.g. a plugin that prints its trigger
/// table, or reads back a trigger's pattern/enabled state to drive UI). The
/// `InfoType` field numbers below are MUSHclient's exactly
/// (`scripting/methods/methods_*.cpp`), so ported plugins read the values they
/// expect. An untracked field or unknown name yields `nil`, matching
/// MUSHclient's `VT_EMPTY`.
public struct AutomationSnapshot: Sendable {
    public var triggers: [TriggerRecord] = []
    public var aliases: [AliasRecord] = []
    public var timers: [TimerRecord] = []
    public init() {}

    /// Trigger names owned by `pluginID` (for `GetPluginTriggerList`) — or, with
    /// `pluginID` nil, every trigger in the snapshot (`GetTriggerList` is scoped
    /// to the calling plugin by the runtime before this is reached).
    public func triggerNames(ownedBy pluginID: String?) -> [String] {
        triggers.compactMap { record in
            guard pluginID == nil || record.owner == pluginID else { return nil }
            return record.name
        }
    }

    public func aliasNames(ownedBy pluginID: String?) -> [String] {
        aliases.compactMap { record in
            guard pluginID == nil || record.owner == pluginID else { return nil }
            return record.name
        }
    }

    public func timerNames(ownedBy pluginID: String?) -> [String] {
        timers.compactMap { record in
            guard pluginID == nil || record.owner == pluginID else { return nil }
            return record.name
        }
    }
}

/// MUSHclient `sendto` codes (submodules/mushclient/OtherTypes.h) — the wire
/// values `GetTriggerInfo(_, 15)` / `GetAliasInfo(_, 18)` / `GetTimerInfo(_, 20)`
/// return, so a plugin re-creating an item from introspection gets the same code.
enum MUSHSendTo {
    static let world = 0
    static let output = 2
    static let execute = 10
    static let script = 12
}

/// One trigger's introspectable fields. ``info`` implements the MUSHclient
/// `GetTriggerInfo` `InfoType` table (`methods_triggers.cpp`).
public struct TriggerRecord: Sendable {
    public let name: String?
    public let owner: String?
    public let match: String
    public let isRegex: Bool
    public let enabled: Bool
    public let gag: Bool
    public let keepEvaluating: Bool
    public let caseSensitive: Bool
    public let sequence: Int
    public let oneShot: Bool
    public let group: String
    public let script: String
    public let sendText: String
    public let sendTo: Int

    /// `GetTriggerInfo(name, infoType)` — a fixed `InfoType → field` lookup
    /// table. Fields Proteles doesn't model (sound, match counts, last-matched
    /// time, wildcards) are absent, so they return `nil` like a MUSHclient
    /// `VT_EMPTY` rather than a fabricated value.
    public func info(_ infoType: Int) -> LuaValue {
        [
            1: .string(match),
            2: .string(sendText),
            4: .string(script),
            6: .boolean(gag),
            7: .boolean(keepEvaluating),
            8: .boolean(enabled),
            9: .boolean(isRegex),
            10: .boolean(!caseSensitive),
            15: .number(Double(sendTo)),
            16: .number(Double(sequence)),
            26: .string(group),
            36: .boolean(oneShot)
        ][infoType] ?? .nil
    }
}

/// One alias's introspectable fields. ``info`` implements MUSHclient
/// `GetAliasInfo` (`methods_aliases.cpp`).
public struct AliasRecord: Sendable {
    public let name: String?
    public let owner: String?
    public let match: String
    public let isRegex: Bool
    public let enabled: Bool
    public let keepEvaluating: Bool
    public let caseSensitive: Bool
    public let sequence: Int
    public let group: String
    public let sendText: String
    public let sendTo: Int

    public func info(_ infoType: Int) -> LuaValue {
        [
            1: .string(match),
            2: .string(sendText),
            3: .string(sendText),
            6: .boolean(enabled),
            7: .boolean(isRegex),
            8: .boolean(!caseSensitive),
            16: .string(group),
            18: .number(Double(sendTo)),
            19: .boolean(keepEvaluating),
            20: .number(Double(sequence))
        ][infoType] ?? .nil
    }
}

/// One timer's introspectable fields. ``info`` implements MUSHclient
/// `GetTimerInfo` (`methods_timers.cpp`). The interval is decomposed into
/// hours/minutes/seconds (infotypes 1–3) as MUSHclient stores it; infotype 13
/// is the live seconds-until-fire, computed against `now`.
public struct TimerRecord: Sendable {
    public let name: String?
    public let owner: String?
    public let schedule: TimerSchedule
    public let enabled: Bool
    public let temporary: Bool
    public let group: String
    public let sendText: String
    public let script: String
    public let sendTo: Int
    /// When the timer is next due, captured at projection time; infotype 13
    /// reports `max(0, fireAt − now)`. Nil when the timer is not scheduled.
    public let fireAt: Date?

    private var isAtTime: Bool { if case .atTimeOfDay = schedule { true } else { false } }
    private var isOneShot: Bool { if case .after = schedule { true } else { false } }

    /// Hours/minutes/seconds the timer is configured with (infotypes 1/2/3),
    /// matching MUSHclient's stored hour/minute/second breakdown.
    private struct Clock { let hour: Int; let minute: Int; let second: Double }
    private var clock: Clock {
        switch schedule {
        case .after(let delay), .every(let delay, _):
            let whole = Int(delay)
            return Clock(
                hour: whole / 3600,
                minute: (whole % 3600) / 60,
                second: delay - Double((whole / 60) * 60)
            )
        case .atTimeOfDay(let hour, let minute, let second):
            return Clock(hour: hour, minute: minute, second: second)
        }
    }

    public func info(_ infoType: Int, now: Date) -> LuaValue {
        let parts = clock
        return [
            1: .number(Double(parts.hour)),
            2: .number(Double(parts.minute)),
            3: .number(parts.second),
            4: .string(sendText),
            5: .string(script),
            6: .boolean(enabled),
            7: .boolean(isOneShot),
            8: .boolean(isAtTime),
            13: .number(max(0, fireAt?.timeIntervalSince(now) ?? 0)),
            14: .boolean(temporary),
            19: .string(group),
            20: .number(Double(sendTo))
        ][infoType] ?? .nil
    }
}
