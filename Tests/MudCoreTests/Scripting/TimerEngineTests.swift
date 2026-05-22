import Foundation
@testable import MudCore
import Testing

@Suite("TimerEngine")
struct TimerEngineTests {
    private let base = Date(timeIntervalSinceReferenceDate: 0)

    private func utcEngine() -> TimerEngine {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return TimerEngine(calendar: calendar)
    }

    // MARK: - .after (one-shot)

    @Test("An .after timer fires once after its delay, then is removed")
    func afterFiresOnceThenRemoved() throws {
        var engine = TimerEngine()
        let id = try engine.add(
            MudTimer(schedule: .after(5), action: .send("ping")),
            now: base
        )

        // Not yet due.
        #expect(engine.due(at: base.addingTimeInterval(4)).isEmpty)
        // Due at the deadline.
        let firings = engine.due(at: base.addingTimeInterval(5))
        #expect(firings.map(\.timerID) == [id])
        #expect(firings.first?.send == "ping")
        // One-shot: gone afterwards.
        #expect(engine.allTimers.isEmpty)
        #expect(engine.due(at: base.addingTimeInterval(100)).isEmpty)
    }

    @Test("An .after(0) timer is due immediately")
    func afterZeroIsImmediate() throws {
        var engine = TimerEngine()
        try engine.add(MudTimer(schedule: .after(0), action: .send("now")), now: base)
        #expect(engine.due(at: base).map(\.send) == ["now"])
    }

    // MARK: - .every (recurring)

    @Test("An .every timer fires on its interval and reschedules")
    func everyRecurs() throws {
        var engine = TimerEngine()
        try engine.add(MudTimer(schedule: .every(10), action: .send("tick")), now: base)

        #expect(engine.due(at: base.addingTimeInterval(9)).isEmpty)
        #expect(engine.due(at: base.addingTimeInterval(10)).map(\.send) == ["tick"])
        // Rescheduled — not due again until +20.
        #expect(engine.due(at: base.addingTimeInterval(15)).isEmpty)
        #expect(engine.due(at: base.addingTimeInterval(20)).map(\.send) == ["tick"])
        // Still present (recurring).
        #expect(engine.allTimers.count == 1)
    }

    @Test("An .every offset delays only the first fire")
    func everyOffsetDelaysFirstFire() throws {
        var engine = TimerEngine()
        try engine.add(MudTimer(schedule: .every(10, offset: 3), action: .send("t")), now: base)
        // First fire is at +3 (the offset), not +10.
        #expect(engine.due(at: base.addingTimeInterval(2)).isEmpty)
        #expect(engine.due(at: base.addingTimeInterval(3)).count == 1)
        // Subsequent fires are one full interval later (+13).
        #expect(engine.due(at: base.addingTimeInterval(12)).isEmpty)
        #expect(engine.due(at: base.addingTimeInterval(13)).count == 1)
    }

    @Test("An overdue recurring timer fires once and rebases (no catch-up storm)")
    func everyCoalescesMissedTicks() throws {
        var engine = TimerEngine()
        try engine.add(MudTimer(schedule: .every(10), action: .send("tick")), now: base)
        // The app slept for ~5 intervals; we wake at +52.
        let firings = engine.due(at: base.addingTimeInterval(52))
        #expect(firings.count == 1) // one fire, not five
        // Rebased to now + interval, so next fire is at +62 (not +60).
        #expect(engine.due(at: base.addingTimeInterval(61)).isEmpty)
        #expect(engine.due(at: base.addingTimeInterval(62)).count == 1)
    }

    // MARK: - .atTimeOfDay

    @Test("An .atTimeOfDay timer fires at the next matching wall-clock time")
    func atTimeOfDayFiresAtNextOccurrence() throws {
        var engine = utcEngine()
        // base is 2001-01-01T00:00:00Z; schedule 06:30:00.
        try engine.add(
            MudTimer(schedule: .atTimeOfDay(hour: 6, minute: 30), action: .send("dawn")),
            now: base
        )
        let sixThirty = base.addingTimeInterval(6 * 3600 + 30 * 60)
        #expect(engine.due(at: sixThirty.addingTimeInterval(-1)).isEmpty)
        #expect(engine.due(at: sixThirty).map(\.send) == ["dawn"])
        // Rescheduled to the same time the next day.
        let nextDay = sixThirty.addingTimeInterval(86400)
        #expect(engine.due(at: nextDay.addingTimeInterval(-1)).isEmpty)
        #expect(engine.due(at: nextDay).count == 1)
    }

    // MARK: - enable / disable / groups

    @Test("A disabled timer never comes due and holds no deadline")
    func disabledTimerInert() throws {
        var engine = TimerEngine()
        let id = try engine.add(MudTimer(schedule: .every(10), action: .send("x")), now: base)
        engine.setEnabled(false, id: id)
        #expect(engine.nextDeadline() == nil)
        #expect(engine.due(at: base.addingTimeInterval(100)).isEmpty)
        // Re-enabling makes it due again (overdue → fires once).
        engine.setEnabled(true, id: id)
        #expect(engine.due(at: base.addingTimeInterval(100)).count == 1)
    }

    @Test("Disabling a group suppresses its timers")
    func groupDisableSuppresses() throws {
        var engine = TimerEngine()
        try engine.add(
            MudTimer(group: "combat", schedule: .every(10), action: .send("bash")),
            now: base
        )
        engine.setGroupEnabled(false, group: "combat")
        #expect(engine.due(at: base.addingTimeInterval(50)).isEmpty)
        engine.setGroupEnabled(true, group: "combat")
        #expect(engine.due(at: base.addingTimeInterval(50)).count == 1)
    }

    // MARK: - ordering / deadline / removal

    @Test("nextDeadline returns the earliest active fire instant")
    func nextDeadlineIsEarliest() throws {
        var engine = TimerEngine()
        try engine.add(MudTimer(schedule: .after(30), action: .send("late")), now: base)
        try engine.add(MudTimer(schedule: .after(5), action: .send("soon")), now: base)
        #expect(engine.nextDeadline() == base.addingTimeInterval(5))
    }

    @Test("due returns firings earliest-scheduled first")
    func dueIsSortedByFireTime() throws {
        var engine = TimerEngine()
        try engine.add(MudTimer(schedule: .after(30), action: .send("late")), now: base)
        try engine.add(MudTimer(schedule: .after(5), action: .send("soon")), now: base)
        let sends = engine.due(at: base.addingTimeInterval(60)).map(\.send)
        #expect(sends == ["soon", "late"])
    }

    @Test("Removing a timer drops it from firing and the deadline")
    func removeDropsTimer() throws {
        var engine = TimerEngine()
        let id = try engine.add(MudTimer(schedule: .every(10), action: .send("x")), now: base)
        engine.remove(id: id)
        #expect(engine.allTimers.isEmpty)
        #expect(engine.nextDeadline() == nil)
        #expect(engine.due(at: base.addingTimeInterval(100)).isEmpty)
    }

    @Test("A script timer surfaces its script, not a send")
    func scriptTimerCarriesScript() throws {
        var engine = TimerEngine()
        try engine.add(MudTimer(schedule: .after(1), action: .script("proteles.echo('hi')")), now: base)
        let firing = engine.due(at: base.addingTimeInterval(1)).first
        #expect(firing?.send == nil)
        #expect(firing?.script == "proteles.echo('hi')")
    }

    // MARK: - validation

    @Test("Invalid schedules are rejected")
    func invalidSchedulesThrow() {
        var engine = TimerEngine()
        #expect(throws: TimerEngine.TimerError.self) {
            try engine.add(MudTimer(schedule: .after(-1), action: .send("x")), now: base)
        }
        #expect(throws: TimerEngine.TimerError.self) {
            try engine.add(MudTimer(schedule: .every(0), action: .send("x")), now: base)
        }
        #expect(throws: TimerEngine.TimerError.self) {
            let timer = MudTimer(schedule: .atTimeOfDay(hour: 24, minute: 0), action: .send("x"))
            try engine.add(timer, now: base)
        }
        #expect(throws: TimerEngine.TimerError.self) {
            let timer = MudTimer(schedule: .atTimeOfDay(hour: 0, minute: 60), action: .send("x"))
            try engine.add(timer, now: base)
        }
    }
}
