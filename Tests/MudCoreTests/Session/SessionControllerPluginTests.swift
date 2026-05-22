import Foundation
@testable import MudCore
import Testing

@Suite("SessionController — plugin loading", .serialized)
struct SessionControllerPluginTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("loadPlugins parses and loads every .xml in a directory")
    func loadsXMLPlugins() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let xml = """
        <muclient>
        <plugin id="com.test.dirplug" name="DirPlug" save_state="y"/>
        <triggers>
        <trigger match="hi" send_to="12"><send>Send("yo")</send></trigger>
        </triggers>
        <script><![CDATA[ function OnPluginInstall() SetVariable("ok", "1") end ]]></script>
        </muclient>
        """
        try xml.write(
            to: directory.appendingPathComponent("dirplug.xml"),
            atomically: true,
            encoding: .utf8
        )

        let engine = try ScriptEngine()
        let controller = SessionController(scriptEngine: engine)
        await controller.loadPlugins(fromDirectory: directory)

        // The plugin's trigger registered and OnPluginInstall ran in scope.
        #expect(await engine.triggerList.count == 1)
        let scopes = await engine.variablesSnapshot()
        #expect(scopes["com.test.dirplug"]?["ok"] == "1")
    }

    @Test("loadPlugins is a no-op for an empty / missing directory")
    func emptyDirectoryNoOp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = try ScriptEngine()
        let controller = SessionController(scriptEngine: engine)
        await controller.loadPlugins(fromDirectory: directory)
        #expect(await engine.triggerList.isEmpty)

        // A directory that doesn't exist is also safe.
        let missing = directory.appendingPathComponent("nope", isDirectory: true)
        await controller.loadPlugins(fromDirectory: missing)
        #expect(await engine.triggerList.isEmpty)
    }
}
