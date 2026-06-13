import Foundation
@testable import MudCore
import Testing

/// An alias whose `sendTo` is `.execute` must re-run its output through the
/// *full* command pipeline (native `mapper`/S&D interception, then alias
/// expansion) — MUSHclient's Execute semantics — not a raw send to the MUD.
///
/// Regression: typing the live `pet` / `twister` aliases (each an execute alias
/// whose body is a `mapper goto …`) sent `mapper goto …` to Aardwolf as raw
/// text ("Unknown command"), because `expandInput` re-ran the body through
/// alias-matching only and then raw-sent it. The native `mapper` handler (which
/// lives in `SessionController.dispatchCommand`) never saw it. The fix: an
/// execute alias emits `.execute` effects (one per line), which the session
/// routes through `dispatchCommand`.
@Suite("Alias Execute — routes through the command pipeline")
struct AliasExecuteRoutingTests {
    @Test("multi-line execute alias → one .execute effect per line (the `pet` case)")
    func multiLineExecuteAliasEmitsPerLineExecuteEffects() async throws {
        let engine = try ScriptEngine()
        try await engine.addAlias(Alias(
            pattern: .exact("pet"),
            caseSensitive: true,
            sendText: "mapper goto 996\nadopt troll",
            sendTo: .execute
        ))
        let effects = await engine.expandInput("pet")
        #expect(effects == [.execute("mapper goto 996"), .execute("adopt troll")])
    }

    @Test("single-line execute alias → a .execute effect, not a raw .send (the `twister` case)")
    func singleLineExecuteAliasReDispatches() async throws {
        let engine = try ScriptEngine()
        try await engine.addAlias(Alias(
            pattern: .wildcard("twister"),
            caseSensitive: true,
            sendText: "mapper goto 29435",
            sendTo: .execute
        ))
        let effects = await engine.expandInput("twister")
        #expect(effects == [.execute("mapper goto 29435")])
    }
}

/// End-to-end through the real ``SessionController`` send path: an Execute
/// alias's output is re-dispatched (so chaining still works), and a
/// self-referential Execute alias terminates instead of hanging.
@Suite("Alias Execute — end-to-end re-dispatch + recursion bound", .serialized)
struct AliasExecuteSessionTests {
    @Test("execute-alias output re-dispatches through the pipeline (chaining reaches the MUD)")
    func executeChainReachesMUD() async throws {
        let engine = try ScriptEngine()
        // "run" → (execute) "go" → (world) "north": the chain resolves only
        // because the session re-dispatches the `.execute` line through the pipeline.
        try await engine.addAlias(Alias(pattern: .exact("run"), sendText: "go", sendTo: .execute))
        try await engine.addAlias(Alias(pattern: .exact("go"), sendText: "north"))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("run")

        #expect(conn.sentLines == ["north"], "execute chain didn't reach the MUD: \(conn.sentLines)")
        await controller.disconnect()
    }

    @Test("a self-referential execute alias terminates without flooding the MUD")
    func selfReferentialExecuteTerminates() async throws {
        let engine = try ScriptEngine()
        try await engine.addAlias(Alias(pattern: .exact("loop"), sendText: "loop", sendTo: .execute))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Must return (the executeDepth cap stops it) rather than hang, and the
        // loop never produces a world send.
        try await controller.send("loop")

        #expect(conn.sentLines.isEmpty, "self-referential execute leaked sends: \(conn.sentLines)")
        await controller.disconnect()
    }
}
