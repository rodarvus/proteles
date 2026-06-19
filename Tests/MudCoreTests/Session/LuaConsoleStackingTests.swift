import Foundation
@testable import MudCore
import Testing

/// A `/lua …` command must bypass command-stacking: Lua statements are
/// `;`-separated (and a `;` can sit inside a string literal), so splitting on
/// `;` first would chop the chunk and send the tail to the MUD as a bogus
/// command. Regression for the player-testing snag where
/// `/lua a; package.path="x;"..p; Note(...)` got chopped at every `;`.
@Suite("SessionController — /lua bypasses command-stacking", .serialized)
struct LuaConsoleStackingTests {
    @Test("a /lua chunk with semicolons runs whole; the tail is not sent to the MUD")
    func luaBypassesStacking() async throws {
        let engine = try ScriptEngine()
        try await engine.loadCompatShim() // installs the `Send` global
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Two Lua statements in one chunk. If `;` split first, only the first
        // runs and ` Send('BETA')` is sent to the MUD as literal text.
        try await controller.send(#"/lua Send("ALPHA"); Send("BETA")"#)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if conn.sentLines.contains("BETA") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Both Lua Send() calls ran → both reach the wire (the whole chunk ran).
        #expect(conn.sentLines.contains("ALPHA"), "first statement didn't run: \(conn.sentLines)")
        #expect(
            conn.sentLines.contains("BETA"),
            "second statement didn't run, chunk was split: \(conn.sentLines)"
        )
        // The literal Lua source must never be sent to the MUD as a command.
        #expect(
            !conn.sentLines.contains { $0.contains("Send(") },
            "a Lua fragment leaked to the MUD: \(conn.sentLines)"
        )
        await controller.disconnect()
    }
}
