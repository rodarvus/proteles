import Foundation
@testable import MudCore
import Testing

/// End-to-end coverage for the `wait` coroutine helper on the shared runtime:
/// a third-party plugin that `require "wait"` and uses `wait.time` / `wait.
/// regexp` must work, driven by the programmatic-automation API
/// (AddTimer/AddTriggerEx) the compat shim now provides.
@Suite("ScriptEngine — wait module")
struct WaitModuleTests {
    /// A plugin that defers a send by a second via `wait.time`, and waits for a
    /// line via `wait.regexp` — exactly the two operations plugins use `wait`
    /// for. Aliases `gotime` / `goline` kick each coroutine off.
    private let plugin = """
    <muclient>
    <plugin id="com.test.waiter" name="Waiter"/>
    <script><![CDATA[
    require "wait"
    function do_time()
      wait.make(function()
        wait.time(1)
        Send("timer done")
      end)
    end
    function do_line()
      wait.make(function()
        local line = wait.regexp("^you feel rested$")
        Send("rested: " .. tostring(line))
      end)
    end
    ]]></script>
    <aliases>
      <alias match="gotime" enabled="y" script="do_time" send_to="12"/>
      <alias match="goline" enabled="y" script="do_line" send_to="12"/>
    </aliases>
    </muclient>
    """

    @Test("require \"async\" loads the native HTTP module (plugin script doesn't abort)")
    func asyncModuleLoads() async throws {
        // A plugin that `require "async"` loads and gets the native HTTP module:
        // `async.doAsyncRemoteRequest` is a real function (the reference's public
        // entry point), so the plugin's alias is defined and usable.
        let xml = """
        <muclient>
        <plugin id="com.test.asyncuser" name="AsyncUser"/>
        <script><![CDATA[
        require "async"
        function go_alias() Send("loaded; doAsyncRemoteRequest is " .. type(async.doAsyncRemoteRequest)) end
        ]]></script>
        <aliases><alias match="go" enabled="y" script="go_alias" send_to="12"/></aliases>
        </muclient>
        """
        let parsed = try MUSHclientPluginLoader.parse(xml: xml)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)
        let effects = await engine.expandInput("go")
        // The alias function exists (script didn't abort) and the async module's
        // public entry point is a real function.
        #expect(effects.contains(.send("loaded; doAsyncRemoteRequest is function")))
    }

    @Test("require \"wait\" loads (no 'module not found')")
    func waitRequires() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: plugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)
        // If require failed, the alias script would error; instead it schedules.
        _ = await engine.expandInput("gotime")
        // wait.make requires timers+triggers "enabled" via GetOption — if that
        // gate failed, nothing would schedule and no timer would be due.
        #expect(await engine.nextTimerDeadline() != nil)
    }

    @Test("wait.time defers a send until the timer fires")
    func waitTimeDefersSend() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: plugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)

        // Kick the coroutine: it schedules a 1s one-shot and yields — nothing
        // sent yet.
        let immediate = await engine.expandInput("gotime")
        #expect(!immediate.contains(.send("timer done")))
        #expect(await engine.takeDidScheduleTimer()) // session would re-arm

        // Before the deadline: still nothing.
        #expect(await engine.fireDueTimers(at: Date()).isEmpty)
        // After the deadline: the coroutine resumes and the send lands.
        let fired = await engine.fireDueTimers(at: Date().addingTimeInterval(1.5))
        #expect(fired.contains(.send("timer done")))
    }

    @Test("wait.regexp resumes the coroutine on a matching line")
    func waitRegexpResumesOnMatch() async throws {
        let parsed = try MUSHclientPluginLoader.parse(xml: plugin)
        let engine = try ScriptEngine()
        await engine.loadPlugin(parsed)

        _ = await engine.expandInput("goline") // registers the wait trigger, yields
        // A non-matching line does nothing.
        _ = await engine.process(line: "you feel hungry")
        // The matching line resumes the coroutine → the send fires.
        let disposition = await engine.process(line: "you feel rested")
        #expect(disposition.effects.contains { effect in
            if case .send(let text) = effect { return text.hasPrefix("rested: ") }
            return false
        })
    }
}
