import Foundation
@testable import MudCore
import Testing

/// Enabling / disabling one library plugin must be **hermetic** — it loads or
/// unloads just that plugin, leaving every other plugin running untouched. The
/// regression this guards: enable/disable used to re-run the *full* world load,
/// re-firing every plugin's `OnPluginInstall` (and tearing down the mapper/S&D).
@Suite("SessionController — hermetic plugin enable/disable", .serialized)
struct PluginHermeticOpsTests {
    /// Write a plugin whose `OnPluginInstall` sends a unique marker, into its own
    /// dir, and return that dir.
    private func makePlugin(id: String, marker: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-\(id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let xml = """
        <muclient>
        <plugin id="\(id)" name="\(id)"/>
        <script><![CDATA[
        function OnPluginInstall() SendNoEcho("\(marker)") end
        ]]></script>
        </muclient>
        """
        try xml.write(to: dir.appendingPathComponent("\(id).xml"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("disable + re-enable one plugin doesn't re-install the others")
    func hermeticToggle() async throws {
        let alpha = try makePlugin(id: "com.test.alpha", marker: "ALPHA")
        let beta = try makePlugin(id: "com.test.beta", marker: "BETA")
        defer { for dir in [alpha, beta] {
            try? FileManager.default.removeItem(at: dir)
        } }

        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        await controller.armInitialPlugins(
            directories: [alpha, beta], character: "Tester", levelDBDirectory: nil
        )
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Go in-game → both plugins load (each installs once).
        await controller.dispatchGMCP(GMCPMessage(package: "char.status", json: #"{"state":3}"#))
        #expect(conn.sentLines.count(where: { $0 == "ALPHA" }) == 1)
        #expect(conn.sentLines.count(where: { $0 == "BETA" }) == 1)

        // Disable Beta, then re-enable it.
        await controller.disablePlugin(id: "com.test.beta", directory: beta)
        await controller.enablePlugin(directory: beta, character: "Tester")

        // Beta re-installed (now twice); Alpha NEVER re-installed (still once) —
        // proving the op touched only Beta, not the whole world.
        #expect(
            conn.sentLines.count(where: { $0 == "ALPHA" }) == 1,
            "Alpha was re-installed by a Beta toggle: \(conn.sentLines)"
        )
        #expect(
            conn.sentLines.count(where: { $0 == "BETA" }) == 2,
            "Beta wasn't re-loaded on re-enable: \(conn.sentLines)"
        )

        await controller.disconnect()
    }
}
