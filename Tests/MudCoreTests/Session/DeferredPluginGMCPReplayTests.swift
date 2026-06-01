import Foundation
@testable import MudCore
import Testing

/// Plugins load late — deferred to the first in-game `char.status` (D-74) — but
/// `char.base` (carrying `tier`/`level`, the inputs an Aardwolf plugin uses to
/// compute the *effective* level for spell selection) arrives during login,
/// before that. A plugin that recomputes on the `char.base` broadcast would miss
/// it entirely (unlike MUSHclient, where plugins load at connect and catch every
/// broadcast), so it'd be stuck at the base level. `activatePluginsIfNeeded`
/// replays the pre-load GMCP to the freshly-loaded plugins to close that gap.
@Suite("Deferred plugins receive pre-load GMCP", .serialized)
struct DeferredPluginGMCPReplayTests {
    /// A plugin that, on each `char.base` broadcast, reports the tier it sees by
    /// sending a marker to the MUD (the `gmcp()` accessor stringifies leaves, so
    /// `tier` reads back as `"4"`).
    private func makePlugin() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmcpreplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let xml = """
        <muclient>
        <plugin id="com.test.gmcpreplay" name="GMCPReplay"/>
        <script><![CDATA[
        require "gmcphelper"
        function OnPluginInstall() SendNoEcho("INSTALLED") end
        function OnPluginBroadcast(msg, id, name, text)
          if text == "char.base" then
            local base = gmcp("char.base")
            SendNoEcho("TIER=" .. tostring(base and base.tier))
          end
        end
        ]]></script>
        </muclient>
        """
        try xml.write(to: dir.appendingPathComponent("gmcpreplay.xml"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("a plugin loaded after char.base still sees its tier")
    func lateLoadedPluginSeesTier() async throws {
        let dir = try makePlugin()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        await controller.armInitialPlugins(directories: [dir], character: "Tester", levelDBDirectory: nil)
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // char.base (tier 4) arrives during login — BEFORE the plugin loads.
        await controller.dispatchGMCP(GMCPMessage(
            package: "char.base", json: #"{"name":"Tester","class":"Psionicist","level":68,"tier":4}"#
        ))
        // First in-game char.status → the plugin loads now; the replay should
        // re-deliver the earlier char.base so its broadcast handler runs.
        await controller.dispatchGMCP(GMCPMessage(package: "char.status", json: #"{"state":3,"level":68}"#))

        #expect(
            conn.sentLines.contains("TIER=4"),
            "late-loaded plugin never saw char.base's tier: \(conn.sentLines)"
        )
        await controller.disconnect()
    }
}
