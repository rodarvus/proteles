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
        await controller.loadPlugins(directories: [directory], profile: UUID())

        // The plugin's trigger registered and OnPluginInstall ran in scope.
        #expect(await engine.triggerList.count == 1)
        let scopes = await engine.variablesSnapshot()
        #expect(scopes["com.test.dirplug"]?["ok"] == "1")
    }

    @Test("Plugin variables persist across sessions (the counter case)")
    func variablesPersistAcrossSessions() async throws {
        let pluginsDir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let xml = """
        <muclient>
        <plugin id="com.test.counter" name="Counter" save_state="y"/>
        <script><![CDATA[
        function OnPluginInstall()
          local n = (tonumber(GetVariable("n")) or 0) + 1
          SetVariable("n", tostring(n))
        end
        ]]></script>
        </muclient>
        """
        try xml.write(
            to: pluginsDir.appendingPathComponent("counter.xml"),
            atomically: true,
            encoding: .utf8
        )
        let variableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-vars-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: variableURL) }

        // First session: install runs once → n = 1, persisted.
        do {
            let engine = try ScriptEngine()
            let controller = SessionController(scriptEngine: engine)
            await controller.attachVariableStore(VariableStore(url: variableURL))
            await controller.loadPlugins(directories: [pluginsDir], profile: UUID())
            #expect(await engine.variablesSnapshot()["com.test.counter"]?["n"] == "1")
        }
        let store = VariableStore(url: variableURL)
        try await store.load()
        #expect(await store.scopes["com.test.counter"]?["n"] == "1")

        // Second session ("relaunch"): hydrate from disk → install bumps to 2.
        do {
            let engine = try ScriptEngine()
            let controller = SessionController(scriptEngine: engine)
            await controller.attachVariableStore(VariableStore(url: variableURL))
            await controller.loadPlugins(directories: [pluginsDir], profile: UUID())
            #expect(await engine.variablesSnapshot()["com.test.counter"]?["n"] == "2")
        }
    }

    @Test("loadPlugins is a no-op for an empty / missing directory")
    func emptyDirectoryNoOp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = try ScriptEngine()
        let controller = SessionController(scriptEngine: engine)
        await controller.loadPlugins(directories: [directory], profile: UUID())
        #expect(await engine.triggerList.isEmpty)

        // A directory that doesn't exist is also safe.
        let missing = directory.appendingPathComponent("nope", isDirectory: true)
        await controller.loadPlugins(directories: [missing], profile: UUID())
        #expect(await engine.triggerList.isEmpty)
    }
}
