import Foundation
@testable import MudCore
import Testing

/// A DB-backed shim plugin opens its SQLite from `proteles.databaseDir()` — the
/// flat per-character `Databases/<char>/` dir where the importer writes it (the
/// same place dinv/leveldb live). The **batch initial-load** path must surface
/// that dir BEFORE any `OnPluginInstall` runs; otherwise `proteles.databaseDir()`
/// is empty, the plugin falls back to its own nested state path, and it never
/// sees the imported DB. Regression: a plugin's data (e.g. its saved rows) came
/// up empty after import because the batch path skipped `setDatabasesDirectory`
/// (only the hermetic single-enable path + dinv/leveldb set it).
@Suite("SessionController — batch load surfaces proteles.databaseDir()", .serialized)
struct SessionControllerPluginDatabaseDirTests {
    @Test("proteles.databaseDir() is non-empty when a plugin installs on initial batch load")
    func databaseDirSetOnBatchLoad() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = """
        <muclient>
        <plugin id="com.test.dbplugin" name="dbplugin"/>
        <script><![CDATA[
        function OnPluginInstall()
          local d = (proteles and proteles.databaseDir) and proteles.databaseDir() or ""
          SendNoEcho("DBDIR[" .. tostring(d) .. "]")
        end
        ]]></script>
        </muclient>
        """
        try xml.write(to: dir.appendingPathComponent("dbplugin.xml"), atomically: true, encoding: .utf8)

        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        await controller.armInitialPlugins(directories: [dir], character: "Tester", levelDBDirectory: nil)
        try await controller.connect(to: .init(host: "test.invalid", port: 23))
        // Go in-game → the batch initial load fires OnPluginInstall.
        await controller.dispatchGMCP(GMCPMessage(package: "char.status", json: #"{"state":3}"#))

        let marker = conn.sentLines.first { $0.hasPrefix("DBDIR[") }
        #expect(marker != nil, "plugin didn't install: \(conn.sentLines)")
        // Was "DBDIR[]" before the fix (batch path never set the dir).
        #expect(marker != "DBDIR[]", "proteles.databaseDir() was empty on batch load")
        #expect(marker?.contains("Databases") == true, "not the flat Databases dir: \(marker ?? "nil")")

        await controller.disconnect()
    }
}
