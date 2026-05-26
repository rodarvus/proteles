import Foundation
@testable import MudCore
import Testing

/// Reproduce, against the REAL ``SessionController`` (its async timer loop +
/// effect application) driven by an ``InMemoryConnection``, the defect the live
/// dinv `build` transcript shows: sends issued from inside a `wait` coroutine
/// aren't transmitted to the MUD until the coroutine chain unwinds.
///
/// Two structures, mirroring dinv's fence/queue:
///  - `go_pre`:  Send BEFORE the first `wait.time` yield (the fence's `echo`).
///  - `go_post`: Send AFTER a `wait.time` yield, i.e. in a timer-resumed
///    continuation (the queue's deferred command flush).
@Suite("SessionController — coroutine send flush", .serialized)
struct CoroutineSendFlushTests {
    private let plugin = """
    <muclient>
    <plugin id="com.test.coflush" name="CoFlush"/>
    <script><![CDATA[
    require "wait"
    function go_pre()
      wait.make(function()
        Send("PRE")
        wait.time(2)
        Send("PRE_AFTER")
      end)
    end
    function go_post()
      wait.make(function()
        wait.time(0.2)
        Send("POST")
      end)
    end
    ]]></script>
    <aliases>
      <alias match="go_pre" enabled="y" script="go_pre" send_to="12"/>
      <alias match="go_post" enabled="y" script="go_post" send_to="12"/>
    </aliases>
    </muclient>
    """

    private func connectedSession() async throws -> (SessionController, InMemoryConnection) {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))
        return (controller, conn)
    }

    /// Poll `conn.sentLines` for `line` up to `timeout`, so we detect a prompt
    /// transmit without waiting the full coroutine duration.
    private func waitForSend(
        _ line: String, on conn: InMemoryConnection, timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if conn.sentLines.contains(line) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return conn.sentLines.contains(line)
    }

    @Test("A Send before wait.time is transmitted promptly (not held to unwind)")
    func sendBeforeWaitFlushes() async throws {
        let (controller, conn) = try await connectedSession()
        try await controller.send("go_pre")
        // "PRE" precedes a 2s wait; it must reach the MUD well before then.
        #expect(
            await waitForSend("PRE", on: conn, timeout: .milliseconds(500)),
            "Send before wait.time was buffered behind the coroutine: \(conn.sentLines)"
        )
        await controller.disconnect()
    }

    @Test("A Send after wait.time (timer-resumed) is transmitted when it runs")
    func sendAfterWaitFlushes() async throws {
        let (controller, conn) = try await connectedSession()
        try await controller.send("go_post")
        // "POST" runs in the 0.2s-timer resume; allow generous slack.
        #expect(
            await waitForSend("POST", on: conn, timeout: .seconds(3)),
            "Send in a timer-resumed coroutine was buffered: \(conn.sentLines)"
        )
        await controller.disconnect()
    }

    /// dinv's `bypass`: a command tagged `DINV_BYPASS ` is meant to skip dinv's
    /// own command queue — `OnPluginSend` strips the tag and re-sends the bare
    /// command "immediately, no questions asked", returning false to drop the
    /// tagged original. MUSHclient guards `OnPluginSend` against re-entrancy
    /// (`doc.cpp`: `m_bPluginProcessingSend` "so we don't go into a loop"), so
    /// that bare re-send reaches the MUD directly. Without the guard, our host
    /// re-runs `OnPluginSend` on the bare command, where the (queue-active)
    /// plugin re-queues it — so it never transmits (dinv's stuck fence echoes).
    private let bypassPlugin = """
    <muclient>
    <plugin id="com.test.bypass" name="Bypass"/>
    <script><![CDATA[
    function OnPluginSend(text)
      local bare = string.match(text, "^BYP (.*)$")
      if bare then SendNoEcho(bare); return false end
      return false  -- non-bypass: swallow it (stand-in for dinv's active queue)
    end
    function fire() SendNoEcho("BYP hello") end
    ]]></script>
    <aliases><alias match="fire" enabled="y" script="fire" send_to="12"/></aliases>
    </muclient>
    """

    @Test("A Send issued from within OnPluginSend bypasses the hook (no re-queue)")
    func onPluginSendReentrancyGuard() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: bypassPlugin))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("fire")
        #expect(
            await waitForSend("hello", on: conn, timeout: .milliseconds(500)),
            "OnPluginSend's bare re-send was re-queued by the hook, not transmitted: \(conn.sentLines)"
        )
        await controller.disconnect()
    }
}
