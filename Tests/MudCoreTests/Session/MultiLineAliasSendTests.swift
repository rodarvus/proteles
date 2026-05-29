import Foundation
@testable import MudCore
import Testing

/// A multi-line alias expansion must reach the MUD as **separate commands**,
/// one per line (MUSHclient's per-line `Send`) — so a "buff" alias whose
/// expansion is several `cast` lines actually casts each spell. Drives the real
/// ``SessionController`` send path via ``InMemoryConnection``.
@Suite("SessionController — multi-line alias send", .serialized)
struct MultiLineAliasSendTests {
    @Test("splitSendLines: single line unchanged; multi-line split; trailing blank dropped")
    func splitRules() {
        #expect(SessionController.splitSendLines("look") == ["look"])
        #expect(SessionController.splitSendLines("") == [""]) // a bare Enter survives
        #expect(SessionController.splitSendLines("cast armor\ncast shield") == ["cast armor", "cast shield"])
        #expect(SessionController.splitSendLines("look\n") == ["look"]) // one trailing blank dropped
        #expect(SessionController.splitSendLines("a\n\nb") == ["a", "", "b"]) // interior blank kept
    }

    /// A world alias whose `<send>` body spans two lines sends two commands.
    private let buffAlias = """
    <muclient>
    <plugin id="bbbbbbbbbbbbbbbbbbbbbbbb" name="Buff"/>
    <aliases>
      <alias match="buff" enabled="y" send_to="0"><send>cast armor
    cast shield</send></alias>
    </aliases>
    </muclient>
    """

    @Test("A multi-line world alias sends each line as its own command")
    func multiLineAliasSendsSeparately() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: buffAlias))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("buff")

        #expect(
            conn.sentLines == ["cast armor", "cast shield"],
            "multi-line alias didn't split into separate commands: \(conn.sentLines)"
        )
        await controller.disconnect()
    }
}
