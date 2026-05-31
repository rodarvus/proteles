import Foundation
@testable import MudCore
import Testing

/// A mid-login `char.status` (Aardwolf state < 3) must NOT be delivered to
/// plugins' `OnPluginBroadcast` — only once the character is in-game (state ≥ 3),
/// matching MUSHclient. Otherwise plugins act prematurely (e.g. Hadar's spellup
/// plugin requests its skill list before login completes, the request fails, and
/// recovery is so slow that spell tracking never works). Drives the real
/// ``SessionController`` GMCP dispatch.
@Suite("SessionController — char.status in-game gate", .serialized)
struct CharStatusGateTests {
    @Test("charStatusState parses Aardwolf's state field")
    func parseState() {
        #expect(SessionController.charStatusState(#"{ "level": 201, "state": 2, "pos": "Standing" }"#) == 2)
        #expect(SessionController.charStatusState(#"{"state":3}"#) == 3)
        #expect(SessionController.charStatusState("{}") == nil)
    }

    /// A plugin that re-broadcasts the char.status state it's told about.
    private let watcher = """
    <muclient>
    <plugin id="com.test.statuswatch" name="StatusWatch"/>
    <script><![CDATA[
    function OnPluginBroadcast(msg, id, name, text)
      if text == "char.status" then SendNoEcho("SAW") end
    end
    ]]></script>
    </muclient>
    """

    @Test("state 2 is held from plugins; the first state-3 is delivered")
    func gatesUntilInGame() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: watcher))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Mid-login status (state 2) → plugins must not see it.
        await controller.dispatchGMCP(GMCPMessage(package: "char.status", json: #"{"state":2}"#))
        #expect(!conn.sentLines.contains("SAW"), "a mid-login char.status reached the plugin")

        // In-game (state 3) → delivered.
        await controller.dispatchGMCP(GMCPMessage(package: "char.status", json: #"{"state":3}"#))
        #expect(
            conn.sentLines.contains("SAW"),
            "the in-game char.status was not delivered: \(conn.sentLines)"
        )

        await controller.disconnect()
    }

    /// A plugin that probes the server from `OnPluginConnect` (the failure mode:
    /// such a command sent during login/MOTD fails).
    private let connector = """
    <muclient>
    <plugin id="com.test.connector" name="Connector"/>
    <script><![CDATA[
    function OnPluginConnect() SendNoEcho("ON_CONNECT") end
    ]]></script>
    </muclient>
    """

    @Test("OnPluginConnect is deferred from the raw connect until in-game")
    func deferredConnect() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: connector))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Mid-login (state 2): OnPluginConnect must not have fired yet.
        await controller.dispatchGMCP(GMCPMessage(package: "char.status", json: #"{"state":2}"#))
        #expect(!conn.sentLines.contains("ON_CONNECT"), "OnPluginConnect fired during login")

        // In-game (state 3): the deferred OnPluginConnect fires now.
        await controller.dispatchGMCP(GMCPMessage(package: "char.status", json: #"{"state":3}"#))
        #expect(
            conn.sentLines.contains("ON_CONNECT"),
            "deferred OnPluginConnect didn't fire in-game: \(conn.sentLines)"
        )

        await controller.disconnect()
    }
}
