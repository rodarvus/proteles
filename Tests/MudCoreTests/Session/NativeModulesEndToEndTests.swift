import Foundation
@testable import MudCore
import Testing

/// Live report (2026-06-10, post-0.7.0): Note mode, the tick countdown, and
/// URL links "stopped working along the way". Each plugin's unit tests pass,
/// so this drives the REAL session pipeline (app-shaped native registration,
/// wire-framed GMCP, the inbound task loop) to find where the wiring drops.
@Suite("native modules — end-to-end through the session", .serialized)
struct NativeModulesEndToEndTests {
    /// Frame a GMCP message as Aardwolf sends it (IAC SB 201 <payload> IAC SE).
    private func gmcpBytes(_ payload: String) -> [UInt8] {
        [255, 250, 201] + Array(payload.utf8) + [255, 240]
    }

    /// The app's full native-plugin set, in ProtelesApp registration order.
    private func registerAll(on engine: ScriptEngine) async {
        _ = await engine.registerNativePlugin(AardGMCPHandler())
        _ = await engine.registerNativePlugin(VitalShortcuts())
        _ = await engine.registerNativePlugin(NoteMode())
        _ = await engine.registerNativePlugin(TextSubstitution())
        _ = await engine.registerNativePlugin(ChatEcho())
        _ = await engine.registerNativePlugin(AsciiMap())
        _ = await engine.registerNativePlugin(ContinentBigmap())
        _ = await engine.registerNativePlugin(TickTimer())
        _ = await engine.registerNativePlugin(URLLinkify())
        _ = await engine.registerNativePlugin(InventorySerialsPlugin())
    }

    private func poll(_ check: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await check()
    }

    @Test("tick countdown: comm.tick anchors gmcpState.lastTick")
    func tickAnchors() async throws {
        let engine = try ScriptEngine()
        await registerAll(on: engine)
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        conn.injectInbound(gmcpBytes(#"char.status { "state": 3 }"#))
        conn.injectInbound(gmcpBytes(#"comm.tick {"ctime" : 1781104511}"#))
        let anchored = await poll { await session.gmcpState.state.lastTick != nil }
        #expect(anchored, "comm.tick never anchored the tick countdown")
        await session.disconnect()
    }

    @Test("note mode: state 5 suspends + announces; state 3 resumes")
    func noteMode() async throws {
        let engine = try ScriptEngine()
        await registerAll(on: engine)
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        conn.injectInbound(gmcpBytes(#"char.status { "state": 3 }"#))
        conn.injectInbound(gmcpBytes(#"char.status { "state": 5 }"#))
        let suspended = await poll { await engine.automationsSuspended }
        #expect(suspended, "state 5 never suspended automations")
        let announced = await poll {
            await session.scrollbackStore.snapshot().contains { $0.text.contains("Note mode") }
        }
        #expect(announced, "the pause never announced")
        conn.injectInbound(gmcpBytes(#"char.status { "state": 3 }"#))
        let resumed = await poll { await !engine.automationsSuspended }
        #expect(resumed, "state 3 never resumed automations")
        await session.disconnect()
    }

    @Test("URL links: an output line lands in scrollback with a clickable run")
    func urlLinks() async throws {
        let engine = try ScriptEngine()
        await registerAll(on: engine)
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        // Live-like display preferences: the tag cleaner + Rich Exits both
        // rewrite display lines, so prove they don't strip link runs.
        await session.setGagTagLines(true)
        await session.setRichExitsEnabled(true)
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        conn.injectLine("Vote at https://aardmud.org/vote today!")
        let linked = await poll {
            await session.scrollbackStore.snapshot().contains { line in
                line.runs.contains { $0.link != nil }
            }
        }
        #expect(linked, "the URL line never gained a link run")
        await session.disconnect()
    }

    @Test("note mode: typed lines bypass the mapper + S&D interception (sent verbatim)")
    func noteModeTypingBypassesInterceptors() async throws {
        guard SnDFixture.install() else { return }
        let engine = try ScriptEngine()
        await registerAll(on: engine)
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        let host = try SearchAndDestroyHost()
        try await host.load()
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        await session.attachSearchAndDestroy(host)
        conn.injectInbound([255, 250, 201] + Array(#"char.status { "state": 3 }"#.utf8) + [255, 240])
        conn.injectInbound([255, 250, 201] + Array(#"char.status { "state": 5 }"#.utf8) + [255, 240])
        _ = await poll { await engine.automationsSuspended }

        // While writing a note, a body line that happens to match an S&D
        // alias (or starts "mapper ...") must reach the wire as note text —
        // S&D ate these before (the "can't write notes" live report).
        try await session.send("xset autonav")
        try await session.send("mapper goto the market")
        #expect(conn.sentLines.contains("xset autonav"), "S&D ate a note line: \(conn.sentLines)")
        #expect(conn.sentLines.contains("mapper goto the market"), "the mapper ate a note line")

        // Resume: interception returns (the S&D alias answers locally again).
        conn.injectInbound([255, 250, 201] + Array(#"char.status { "state": 3 }"#.utf8) + [255, 240])
        _ = await poll { await !engine.automationsSuspended }
        let before = conn.sentLines.count
        try await session.send("xset autonav")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(conn.sentLines.count == before, "post-note, the S&D alias should answer locally")
        await session.disconnect()
    }

    @Test("chat lines linkify at ingestion and map into the attributed string")
    func chatLinks() async {
        let store = ChatStore()
        let chatLine = await store.append(
            channel: "gametalk",
            player: "Wire",
            message: "@Wcheck https://aardwolf.fandom.com/wiki for details@w"
        )
        #expect(chatLine.line.runs.contains { run in
            if case .openURL(let url)? = run.link?.action { return url.contains("aardwolf.fandom.com") }
            return false
        }, "chat ingestion never linkified the URL")
    }
}
