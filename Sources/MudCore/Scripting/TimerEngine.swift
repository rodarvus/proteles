import Foundation

/// When a ``MudTimer`` should fire. Both MUSHclient (`eInterval`/`eAtTime`)
/// and Mudlet (interval-only `tempTimer`) shapes are covered, with explicit
/// cases so the intent is never ambiguous.
public enum TimerSchedule: Sendable, Equatable, Codable {
    /// Fire once after `delay` seconds, then remove the timer (Mudlet's
    /// `tempTimer`). `delay` may be `0` (fire on the next tick).
    case after(TimeInterval)
    /// Fire every `interval` seconds (MUSHclient `eInterval`). `offset`
    /// delays only the *first* fire; when `0` the first fire is one full
    /// `interval` from now. `interval` must be positive.
    case every(TimeInterval, offset: TimeInterval = 0)
    /// Fire daily at a wall-clock time (MUSHclient `eAtTime`). `second`
    /// may be fractional.
    case atTimeOfDay(hour: Int, minute: Int, second: Double = 0)
}

/// What a timer does when it fires. Modelled as a single payload (unlike
/// MUSHclient/Mudlet, which carry both a send string and a script slot on
/// every timer): a timer either sends text or runs a script.
public enum TimerAction: Sendable, Equatable, Codable {
    /// Send text to the MUD.
    case send(String)
    /// Run Lua (the host provides no captures).
    case script(String)

    var sendText: String? {
        guard case .send(let text) = self else { return nil }
        return text
    }

    var scriptText: String? {
        guard case .script(let text) = self else { return nil }
        return text
    }
}

/// A scheduled action. A pure value type — the engine decides *when* it is
/// due; the host (``SessionController``) performs the send/script. `label`
/// and `temporary` are metadata for the UI/persistence layers; the engine
/// keys everything off ``id``.
public struct MudTimer: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID
    /// Human-facing name (optional). Unused by matching — kill/enable is by
    /// ``id`` to avoid Mudlet's id-vs-name overload ambiguity.
    public var label: String?
    /// Optional group for bulk enable/disable.
    public var group: String?
    public var schedule: TimerSchedule
    public var action: TimerAction
    public var enabled: Bool
    /// When true, this timer is not persisted (Mudlet `tempTimer`).
    public var temporary: Bool

    public init(
        id: UUID = UUID(),
        label: String? = nil,
        group: String? = nil,
        schedule: TimerSchedule,
        action: TimerAction,
        enabled: Bool = true,
        temporary: Bool = false
    ) {
        self.id = id
        self.label = label
        self.group = group
        self.schedule = schedule
        self.action = action
        self.enabled = enabled
        self.temporary = temporary
    }
}

/// A timer that came due, with the action to apply. The host turns this into
/// a send or a script run.
public struct TimerFiring: Sendable, Equatable {
    public let timerID: UUID
    /// Text to send (for a `.send` action).
    public let send: String?
    /// Lua to run (for a `.script` action).
    public let script: String?
}

/// Schedules timed sends/scripts (ARCHITECTURE.md §8.6). A pure value type: it tracks
/// each timer's next fire instant and reports which ones are due at a given
/// `Date`, but never sleeps or sends — the host drives the clock.
///
/// Time is wall-clock (`Date`), mirroring MUSHclient: this makes
/// ``atTimeOfDay`` natural and lets a single anti-drift rule handle both
/// machine sleep and clock changes. When a recurring timer is overdue (the
/// app slept, or many ticks were missed), it fires **once** and rebases to
/// `now + interval` rather than replaying every missed tick — MUSHclient's
/// behaviour, without its snapshot-and-relookup contortions (the value-type
/// model and the actor host make re-entrancy a non-issue).
public struct TimerEngine {
    public enum TimerError: Error, Equatable {
        case invalidSchedule(String)
    }

    private var timers: [MudTimer] = []
    private var nextFire: [UUID: Date] = [:]
    private let calendar: Calendar

    /// - Parameter calendar: used only for ``TimerSchedule/atTimeOfDay``.
    ///   Injectable so time-of-day tests can pin a timezone.
    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// All timers, in insertion order.
    public var allTimers: [MudTimer] {
        timers
    }

    /// Add a timer, computing its first fire relative to `now`. Throws on an
    /// invalid schedule (non-positive interval, out-of-range time of day).
    @discardableResult
    public mutating func add(_ timer: MudTimer, now: Date = Date()) throws -> UUID {
        try Self.validate(timer.schedule)
        nextFire[timer.id] = firstFire(for: timer.schedule, now: now)
        timers.append(timer)
        return timer.id
    }

    /// Remove a timer by id.
    public mutating func remove(id: UUID) {
        timers.removeAll { $0.id == id }
        nextFire[id] = nil
    }

    /// Enable or disable a single timer.
    public mutating func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[index].enabled = enabled
    }

    /// Enable/disable every timer in a group (MUSHclient bulk-sets each member's
    /// individual `enabled` flag; an individual enable later overrides).
    public mutating func setGroupEnabled(_ enabled: Bool, group: String) {
        for index in timers.indices where timers[index].group == group {
            timers[index].enabled = enabled
        }
    }

    /// The earliest fire instant among the active timers, or `nil` when none
    /// are scheduled. The host sleeps until this to drive ``due(at:)``.
    public func nextDeadline() -> Date? {
        timers.compactMap { timer in
            isActive(timer) ? nextFire[timer.id] : nil
        }.min()
    }

    /// The timers due at `now`, earliest-scheduled first. Each due timer
    /// fires at most once per call (overdue recurring timers coalesce).
    /// Recurring timers are rescheduled; one-shots are removed.
    public mutating func due(at now: Date) -> [TimerFiring] {
        let dueTimers = timers
            .compactMap { timer -> (MudTimer, Date)? in
                guard isActive(timer), let fire = nextFire[timer.id], fire <= now else {
                    return nil
                }
                return (timer, fire)
            }
            .sorted { $0.1 < $1.1 }

        var firings: [TimerFiring] = []
        var oneShotsToRemove: [UUID] = []
        for (timer, fire) in dueTimers {
            firings.append(TimerFiring(
                timerID: timer.id,
                send: timer.action.sendText,
                script: timer.action.scriptText
            ))
            switch timer.schedule {
            case .after:
                oneShotsToRemove.append(timer.id)
            case .every(let interval, _):
                var next = fire.addingTimeInterval(interval)
                if next <= now { next = now.addingTimeInterval(interval) }
                nextFire[timer.id] = next
            case .atTimeOfDay(let hour, let minute, let second):
                nextFire[timer.id] = nextTimeOfDay(
                    hour: hour, minute: minute, second: second, after: now
                )
            }
        }
        for id in oneShotsToRemove {
            remove(id: id)
        }
        return firings
    }

    // MARK: - Private

    private func isActive(_ timer: MudTimer) -> Bool {
        timer.enabled
    }

    private func firstFire(for schedule: TimerSchedule, now: Date) -> Date {
        switch schedule {
        case .after(let delay):
            now.addingTimeInterval(delay)
        case .every(let interval, let offset):
            now.addingTimeInterval(offset > 0 ? offset : interval)
        case .atTimeOfDay(let hour, let minute, let second):
            nextTimeOfDay(hour: hour, minute: minute, second: second, after: now)
        }
    }

    private func nextTimeOfDay(hour: Int, minute: Int, second: Double, after now: Date) -> Date {
        let whole = Int(second.rounded(.down))
        let fraction = second - Double(whole)
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = whole
        let base = calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(86400)
        return fraction > 0 ? base.addingTimeInterval(fraction) : base
    }

    private static func validate(_ schedule: TimerSchedule) throws {
        switch schedule {
        case .after(let delay):
            guard delay >= 0 else { throw TimerError.invalidSchedule("delay must be >= 0") }
        case .every(let interval, let offset):
            guard interval > 0 else { throw TimerError.invalidSchedule("interval must be > 0") }
            guard offset >= 0 else { throw TimerError.invalidSchedule("offset must be >= 0") }
        case .atTimeOfDay(let hour, let minute, let second):
            guard (0...23).contains(hour) else { throw TimerError.invalidSchedule("hour 0-23") }
            guard (0...59).contains(minute) else { throw TimerError.invalidSchedule("minute 0-59") }
            guard (0..<60).contains(second) else {
                throw TimerError.invalidSchedule("second must be in [0, 60) — fractions allowed")
            }
        }
    }
}
