import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclient world-level timers → Proteles MudTimer")
struct MUSHclientTimerImportTests {
    @Test("parses + maps interval, one-shot, and at-time timers")
    func mapsTimers() throws {
        let mcl = """
        <muclient><world name="W" site="h" port="23"></world>
        <timers>
          <timer name="tick" enabled="y" second="2.00" offset_second="1.00" send_to="12">
            <send>DoTick()</send></timer>
          <timer name="once" enabled="y" minute="5" one_shot="y" send_to="0">
            <send>say boo</send></timer>
          <timer name="dawn" enabled="n" at_time="y" hour="6" minute="30" send_to="0">
            <send>wake</send></timer>
          <timer name="empty" second="1.0"><send></send></timer>
        </timers></muclient>
        """
        let world = try #require(MUSHclientWorldParser.parse(Data(mcl.utf8)))
        #expect(world.timers.count == 4)
        let timers = MUSHclientScriptMapping.timers(from: world.timers)
        #expect(timers.count == 3) // empty body dropped

        let tick = try #require(timers.first { $0.label == "tick" })
        #expect(tick.schedule == .every(2, offset: 1))
        #expect(tick.action == .script("DoTick()"))
        #expect(tick.enabled && !tick.temporary)

        let once = try #require(timers.first { $0.label == "once" })
        #expect(once.schedule == .after(300)) // 5 minutes, one-shot
        #expect(once.action == .send("say boo") && once.temporary)

        let dawn = try #require(timers.first { $0.label == "dawn" })
        #expect(dawn.schedule == .atTimeOfDay(hour: 6, minute: 30, second: 0))
        #expect(!dawn.enabled)
    }
}
