import Foundation
@testable import MudCore
import Testing

/// Typed input is split once before alias/plugin expansion. No-match commands
/// must not be command-stack split again after the script engine passes them
/// through, or an escaped `;;` literal becomes a real separator.
@Suite("SessionController — typed command stacking", .serialized)
struct TypedCommandStackTests {
    private func send(_ command: String) async throws -> [String] {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send(command)

        let sent = conn.sentLines
        await controller.disconnect()
        return sent
    }

    @Test("single semicolon splits typed input")
    func singleSemicolonSplits() async throws {
        let sent = try await send("north;south")
        #expect(sent == ["north", "south"], "expected command stack split, got \(sent)")
    }

    @Test("doubled semicolon is one literal semicolon in typed input")
    func doubledSemicolonIsLiteral() async throws {
        let sent = try await send("say hi;;there")
        #expect(sent == ["say hi;there"], "escaped semicolon was split twice: \(sent)")
    }

    @Test("literal semicolon followed by separator splits once")
    func literalThenSeparator() async throws {
        let sent = try await send("north;;;south")
        #expect(sent == ["north;", "south"], "expected literal ; then split: \(sent)")
    }
}
