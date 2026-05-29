import Foundation
@testable import MudCore
import Testing

/// A bare Enter on an empty input line must reach the MUD as `\r\n` — MUDs use
/// it to refresh the prompt and page output ("Press <RETURN> to continue").
/// These drive the REAL ``SessionController`` send path (via
/// ``InMemoryConnection``) to pin that an empty command is transmitted, not
/// swallowed, in the configurations the live app actually runs.
@Suite("SessionController — empty line send", .serialized)
struct EmptyLineSendTests {
    /// `sentLines` filters empties, so assert on the raw outbound chunks.
    private func sentBareNewline(_ conn: InMemoryConnection) -> Bool {
        conn.sentBytes.contains([UInt8]("\r\n".utf8))
    }

    @Test("With a script engine, send(\"\") transmits a bare \\r\\n")
    func emptyLineWithScriptEngine() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("")

        #expect(
            sentBareNewline(conn),
            "empty input was swallowed instead of sent as \\r\\n: \(conn.sentBytes)"
        )
        await controller.disconnect()
    }

    @Test("Without a script engine, send(\"\") transmits a bare \\r\\n")
    func emptyLineVerbatim() async throws {
        let conn = InMemoryConnection()
        let controller = SessionController(makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("")

        #expect(
            sentBareNewline(conn),
            "empty input was swallowed instead of sent as \\r\\n: \(conn.sentBytes)"
        )
        await controller.disconnect()
    }

    /// The live-bug repro. A loaded catch-all alias (`match="^(.*)$"`, exactly
    /// as the Aardwolf `aard_GMCP_mapper` package and many personal plugins ship
    /// one) matches the empty string and, firing a script that produces no
    /// world send, swallows the bare Enter — so it never reaches the MUD. The
    /// fix sends an empty line raw, bypassing alias expansion (MUSHclient's
    /// `Execute`: "empty line - just send it"), so the catch-all can't eat it.
    private let catchAllPlugin = """
    <muclient>
    <plugin id="aaaaaaaaaaaaaaaaaaaaaaaa" name="CatchAll"/>
    <aliases>
      <alias match="^(.*)$" enabled="y" regexp="y" script="caught"
             send_to="12" keep_evaluating="n"/>
    </aliases>
    <script><![CDATA[
    function caught() Note("caught: [%1]") end
    ]]></script>
    </muclient>
    """

    @Test("A catch-all ^(.*)$ alias does not swallow the bare Enter")
    func emptyLineSurvivesCatchAllAlias() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: catchAllPlugin))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Sanity: the catch-all really does match a typed line (so the empty
        // case below is a genuine bypass, not a non-matching alias).
        try await controller.send("hello")
        try await controller.send("")

        #expect(
            sentBareNewline(conn),
            "a catch-all alias swallowed the empty line; it never reached the MUD: \(conn.sentBytes)"
        )
        await controller.disconnect()
    }
}
