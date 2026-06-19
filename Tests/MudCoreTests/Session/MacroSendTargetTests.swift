import Foundation
@testable import MudCore
import Testing

/// Macro send-types mirror aliases: `.send` is a raw "Send to MUD" (no
/// alias/mapper/S&D re-processing), while `.command` is "Re-process as input"
/// (runs through the full pipeline, so aliases apply). Both split a multi-line
/// body and honour `;`-stacking. Drives the real ``SessionController`` via
/// ``InMemoryConnection``.
@Suite("SessionController — macro send targets", .serialized)
struct MacroSendTargetTests {
    /// Fire `action` with an alias `gg → get all` loaded, returning what reached
    /// the MUD — so we can tell a raw send (`gg`) from a re-processed one (`get all`).
    private func fireWithGGAlias(_ action: MacroAction) async throws -> [String] {
        let engine = try ScriptEngine()
        try await engine.addAlias(Alias(pattern: .exact("gg"), sendText: "get all"))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))
        await controller.fire(action)
        let sent = conn.sentLines
        await controller.disconnect()
        return sent
    }

    @Test(".send goes raw to the MUD, bypassing aliases")
    func rawSendBypassesAliases() async throws {
        let sent = try await fireWithGGAlias(.send("gg"))
        #expect(sent == ["gg"], "raw send should not expand the gg alias: \(sent)")
    }

    @Test(".command re-processes as input, expanding aliases")
    func commandReprocessesAliases() async throws {
        let sent = try await fireWithGGAlias(.command("gg"))
        #expect(sent == ["get all"], "command should re-process through the gg alias: \(sent)")
    }

    @Test(".send honours ;-stacking and multi-line")
    func rawSendSplits() async throws {
        let sent = try await fireWithGGAlias(.send("a;b\nc"))
        #expect(sent == ["a", "b", "c"], "got \(sent)")
    }

    @Test("MacroAction round-trips .send through Codable")
    func codableRoundTripsSend() throws {
        let action = MacroAction.send("cast armor\ncast shield")
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(MacroAction.self, from: data)
        #expect(decoded == action)
    }
}
