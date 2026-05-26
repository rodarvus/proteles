import Foundation
@testable import MudCore
import Testing

/// Full-context reproduction of the live portal-navigation failure: a mapper
/// `goto` whose path crosses a portal emits the portal's use-command (a dinv
/// alias) as `.execute`; that runs through the REAL SessionController pipeline
/// to a dinv-like plugin which issues a bypass send. Live, every such send went
/// out *twice*, corrupting the hold→enter→wear sequence. This wires the real
/// Mapper + SessionController + InMemoryConnection + a minimal dinv stand-in to
/// pin whether (and where) the command doubles.
@Suite("SessionController — portal navigation (doubling repro)", .serialized)
struct PortalNavigationTests {
    /// Minimal dinv stand-in: a `dinv portal use <id>` alias that issues a
    /// bypass send (like dinv's portal hold), plus the DINV_BYPASS OnPluginSend
    /// strip. Mirrors the exact send shape that doubled live.
    private let dinvLike = """
    <muclient>
    <plugin id="com.test.dinvlike" name="DinvLike"/>
    <script><![CDATA[
    delaying = false
    function OnPluginSend(text)
      local bare = string.match(text, "^BYP (.*)$")
      if bare then SendNoEcho(bare); return false end
      if delaying then return false end
      return true
    end
    function portal_use()
      delaying = true
      SendNoEcho("BYP hold " .. matches[1])
    end
    ]]></script>
    <aliases>
      <alias match="^dinv portal use (.*)$" regexp="y" enabled="y" script="portal_use" send_to="12"/>
    </aliases>
    </muclient>
    """

    @Test("A portal hop in a mapper goto issues its plugin send exactly once")
    func portalHopSendNotDoubled() async throws {
        // Mapper with a far room reachable ONLY via a portal whose use-command
        // is `dinv portal use 999`.
        let mapURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portal-nav-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: mapURL) }
        let mapper = try Mapper(store: MapperStore(url: mapURL))
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":4,"name":"Far Vault","zone":"z","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Start","zone":"z","exits":{}}"#
        )
        _ = await mapper.handleCommand("mapper fullportal {dinv portal use 999} {4} 0")

        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: dinvLike))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        await controller.attachMapper(mapper)
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("mapper goto 4")

        // Give async dispatch a beat to flush.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < deadline {
            if conn.sentLines.contains("hold 999") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let holds = conn.sentLines.count(where: { $0 == "hold 999" })
        #expect(holds == 1, "portal hop send doubled (count=\(holds)): \(conn.sentLines)")
        await controller.disconnect()
    }
}
