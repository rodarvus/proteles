import Foundation
@testable import MudCore
import Testing

/// A "Send to MUD" (`.world`) alias whose expansion contains client-side
/// command stacking (`;`) must reach the MUD as **separate commands** — the
/// Aardwolf/MUSHclient convention — while a doubled `;;` stays a literal `;`.
/// This rode only the typed-input path before; the alias expansion output now
/// honours it too. Drives the real ``SessionController`` send path via
/// ``InMemoryConnection``.
@Suite("SessionController — alias .world send honours ;-stacking", .serialized)
struct AliasSemicolonSendTests {
    private func run(_ sendText: String) async throws -> [String] {
        let engine = try ScriptEngine()
        try await engine.addAlias(Alias(pattern: .exact("go"), sendText: sendText))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))
        try await controller.send("go")
        let sent = conn.sentLines
        await controller.disconnect()
        return sent
    }

    @Test("a `;` in a world-alias expansion splits into separate commands")
    func splitsSemicolons() async throws {
        let sent = try await run("get all;wear all")
        #expect(sent == ["get all", "wear all"], "expected a ;-split, got \(sent)")
    }

    @Test("`;;` is a literal semicolon, not a split")
    func doubledSemicolonIsLiteral() async throws {
        let sent = try await run("say hi;;there")
        #expect(sent == ["say hi;there"], "expected one literal-; command, got \(sent)")
    }

    @Test("`;` combines with multi-line expansion")
    func semicolonAndNewline() async throws {
        let sent = try await run("get all;wear all\ndrop trash")
        #expect(sent == ["get all", "wear all", "drop trash"], "got \(sent)")
    }

    @Test("a trailing `;` emits no spurious blank command")
    func trailingSemicolon() async throws {
        let sent = try await run("n;")
        #expect(sent == ["n"], "trailing ; should not send a bare Enter: \(sent)")
    }
}
