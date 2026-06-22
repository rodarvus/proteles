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

    @Test("a shim one-shot AddTimer stops existing after it fires (re-arm idiom)")
    func shimOneShotClearsAfterFire() async throws {
        // Regression for the DullTracker level-doubling: a one-shot AddTimer must
        // report gone via IsTimer once it fires (MUSHclient deletes one-shots on
        // fire), so the pervasive `if IsTimer(x) ~= eOK then AddTimer(...)` re-arm
        // idiom works. Before the fix IsTimer stayed eOK forever → no re-arm.
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.ot" name="OT"/>
        <script><![CDATA[
        function ot_fire() proteles.send("fired") end
        function OnPluginInstall()
          AddTimer("ot", 0, 0, 1, "", timer_flag.Enabled + timer_flag.OneShot, "ot_fire")
        end
        ]]></script></muclient>
        """)
        _ = try await engine.loadPlugin(plugin)
        let before = await engine.evaluateConsole(
            "proteles.echo(tostring(IsTimer('ot') == error_code.eOK))", inPlugin: "com.ot"
        )
        #expect(before.contains(.echo("true")))
        let fired = await engine.fireDueTimers(at: Date().addingTimeInterval(5))
        #expect(fired.contains(.send("fired")))
        let after = await engine.evaluateConsole(
            "proteles.echo(tostring(IsTimer('ot') == error_code.eOK))", inPlugin: "com.ot"
        )
        #expect(after.contains(.echo("false")))
    }

    @Test("GetTimerInfo infotype 13 returns seconds-to-go for a shim timer")
    func shimTimerInfoSecondsToGo() async throws {
        // Regression for Aard_Affects' 0:00 countdowns: shim timers must answer
        // infotype 13 (seconds remaining), not nil.
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.ti" name="TI"/>
        <script><![CDATA[
        function ti_fire() end
        function OnPluginInstall()
          AddTimer("ti", 0, 1, 0, "", timer_flag.Enabled, "ti_fire")
        end
        ]]></script></muclient>
        """)
        _ = try await engine.loadPlugin(plugin)
        let result = await engine.evaluateConsole(
            "local s = GetTimerInfo('ti', 13); proteles.echo(tostring(s ~= nil and s > 0 and s <= 60))",
            inPlugin: "com.ti"
        )
        #expect(result.contains(.echo("true")))
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
