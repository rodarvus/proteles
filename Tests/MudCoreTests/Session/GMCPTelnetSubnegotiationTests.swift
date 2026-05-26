import Foundation
@testable import MudCore
import Testing

/// dinv's GMCP config detection (`dbot.gmcp.getConfig`) reads config values only
/// from `OnPluginTelnetSubnegotiation(201, "config { … }")` — MUSHclient fires
/// that for the raw GMCP subnegotiation. We previously delivered GMCP only to
/// `OnPluginBroadcast`, so every `getConfig` timed out at 5s and dinv fell back
/// to defaults (a ~10s init delay each connect). This verifies an inbound GMCP
/// packet now reaches a plugin's `OnPluginTelnetSubnegotiation`, with Aardwolf's
/// exact spacing preserved (dinv's pattern needs `{ "key" : "value" }`).
@Suite("SessionController — GMCP → OnPluginTelnetSubnegotiation", .serialized)
struct GMCPTelnetSubnegotiationTests {
    private let plugin = """
    <muclient>
    <plugin id="com.test.telnetsub" name="TelnetSub"/>
    <script><![CDATA[
    function OnPluginTelnetSubnegotiation(msgType, data)
      if msgType == 201 then
        local key, value = string.match(data, "config { \\"([%w_]+)\\" : \\"([%w_]+)\\" }")
        if key then SetVariable("seen_" .. key, value) end
      end
    end
    ]]></script>
    </muclient>
    """

    @Test("An inbound config GMCP reaches OnPluginTelnetSubnegotiation(201, …)")
    func gmcpReachesTelnetSubnegotiation() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Deliver the exact shape Aardwolf sends in reply to `sendgmcp config X`.
        await controller.dispatchGMCP(GMCPMessage(
            package: "config", json: #"{ "prompt" : "YES" }"#
        ))

        let seen = await engine.variablesSnapshot()["com.test.telnetsub"]?["seen_prompt"]
        #expect(seen == "YES", "plugin did not receive config via telnet subnegotiation: \(seen ?? "nil")")
        await controller.disconnect()
    }
}
