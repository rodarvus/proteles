import Foundation
@testable import MudCore
import Testing

@Suite("ScriptEngine — timers")
struct ScriptEngineTimerTests {
    private let base = Date(timeIntervalSinceReferenceDate: 0)

    @Test("A due send timer produces a .send effect")
    func sendTimerFires() async throws {
        let engine = try ScriptEngine()
        try await engine.addTimer(
            MudTimer(schedule: .every(10), action: .send("save")),
            now: base
        )
        #expect(await engine.fireDueTimers(at: base.addingTimeInterval(9)).isEmpty)
        let effects = await engine.fireDueTimers(at: base.addingTimeInterval(10))
        #expect(effects == [.send("save")])
    }

    @Test("A due script timer runs Lua and surfaces its effects")
    func scriptTimerRunsLua() async throws {
        let engine = try ScriptEngine()
        try await engine.addTimer(
            MudTimer(schedule: .after(1), action: .script("proteles.send('tick')")),
            now: base
        )
        let effects = await engine.fireDueTimers(at: base.addingTimeInterval(1))
        #expect(effects == [.send("tick")])
    }

    @Test("nextTimerDeadline reports the earliest scheduled fire")
    func deadlineReported() async throws {
        let engine = try ScriptEngine()
        try await engine.addTimer(MudTimer(schedule: .after(30), action: .send("a")), now: base)
        try await engine.addTimer(MudTimer(schedule: .after(5), action: .send("b")), now: base)
        #expect(await engine.nextTimerDeadline() == base.addingTimeInterval(5))
    }

    @Test("A removed timer no longer fires")
    func removedTimerSilent() async throws {
        let engine = try ScriptEngine()
        let id = try await engine.addTimer(
            MudTimer(schedule: .every(10), action: .send("x")),
            now: base
        )
        await engine.removeTimer(id: id)
        #expect(await engine.fireDueTimers(at: base.addingTimeInterval(100)).isEmpty)
        #expect(await engine.timerList.isEmpty)
    }
}
