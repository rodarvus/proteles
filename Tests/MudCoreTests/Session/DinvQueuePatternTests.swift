import Foundation
@testable import MudCore
import Testing

/// Reproduce dinv's `dbot.execute` command-queue pattern against the REAL
/// ``SessionController`` (async timer loop + send path) via an
/// ``InMemoryConnection``: a `wait.make` coroutine runs a *prefix fence*
/// (register a one-shot trigger, `SendNoEcho("echo FENCE n")`, then spin on
/// `wait.time` until the echo round-trips and the trigger sets a flag), then
/// sends the real command, then a *suffix fence*. The live transcript shows the
/// prefix fence completing but the real command never transmitting — this pins
/// that stall in `swift test`.
@Suite("SessionController — dinv queue/fence pattern", .serialized)
struct DinvQueuePatternTests {
    private let plugin = """
    <muclient>
    <plugin id="com.test.queue" name="Queue"/>
    <script><![CDATA[
    require "wait"
    delaying = false
    -- dinv's bypass: a BYP-tagged send is stripped + re-sent here; while the
    -- queue is "delaying", every other command is swallowed (queued).
    function OnPluginSend(text)
      local bare = string.match(text, "^BYP (.*)$")
      if bare then SendNoEcho(bare); return false end
      if delaying then return false end
      return true
    end
    fenceN = 0
    function fence()
      fenceN = fenceN + 1
      local tag = "{ DINV fence " .. fenceN .. " }"
      fenceDone = false
      AddTriggerEx("fnc", "^" .. tag .. "$", "fenceDone = true",
                   trigger_flag.Enabled + trigger_flag.RegularExpression + trigger_flag.OneShot,
                   custom_colour.NoChange, 0, "", "", sendto.script, 0)
      SendNoEcho("BYP echo " .. tag)        -- bypass send
      local t = 0
      while (not fenceDone) and (t < 30) do wait.time(0.1); t = t + 0.1 end
    end
    function run_queue()
      delaying = true
      wait.make(function()
        fence()                     -- prefix fence
        SendNoEcho("BYP REALCMD")   -- the safe command (bypass)
        fence()                     -- suffix fence
        delaying = false
        SendNoEcho("BYP QUEUE_DONE")
      end)
    end
    ]]></script>
    <aliases><alias match="rq" enabled="y" script="run_queue" send_to="12"/></aliases>
    </muclient>
    """

    @Test("dbot.execute-style fence/dequeue transmits the queued command")
    func queuedCommandTransmits() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("rq")

        // Drive the loop: the "MUD" echoes `echo FENCE n` back as `FENCE n`,
        // which fires the fence trigger and resumes the coroutine. Generous
        // deadline — the coroutine rides `wait.time` timers on the
        // SessionController loop, which can be starved several seconds under
        // `swift test --parallel` on CI; the loop breaks early once it's done.
        var answered = Set<String>()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            for line in conn.sentLines where line.hasPrefix("echo { DINV fence ") {
                let reply = String(line.dropFirst("echo ".count))
                if answered.insert(reply).inserted { conn.injectLine(reply) }
            }
            if conn.sentLines.contains("QUEUE_DONE") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let sent = conn.sentLines
        #expect(sent.contains("REALCMD"), "queued safe command never transmitted: \(sent)")
        #expect(sent.contains("QUEUE_DONE"), "queue did not run to completion: \(sent)")
        await controller.disconnect()
    }
}
