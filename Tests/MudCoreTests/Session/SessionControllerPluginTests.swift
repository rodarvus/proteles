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
        await controller.loadPlugins(directories: [directory], character: "test")

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
            await controller.loadPlugins(directories: [pluginsDir], character: "test")
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
            await controller.loadPlugins(directories: [pluginsDir], character: "test")
            #expect(await engine.variablesSnapshot()["com.test.counter"]?["n"] == "2")
        }
    }

    @Test("SaveState variable survives an immediate ReloadPlugin")
    func saveStatePersistsBeforeReload() async throws {
        let pluginsDir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let xml = """
        <muclient>
        <plugin id="com.test.save-reload" name="Save Reload" save_state="y"/>
        <aliases>
          <alias match="^save-reload$" enabled="y" regexp="y" send_to="12">
            <send>
              SaveState()
              ReloadPlugin(GetPluginID())
            </send>
          </alias>
        </aliases>
        <script><![CDATA[
        function OnPluginSaveState()
          SetVariable("saved_marker", "yes")
        end
        ]]></script>
        </muclient>
        """
        try xml.write(
            to: pluginsDir.appendingPathComponent("save-reload.xml"),
            atomically: true,
            encoding: .utf8
        )
        let variableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-vars-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: variableURL) }

        let engine = try ScriptEngine()
        let controller = SessionController(scriptEngine: engine)
        await controller.attachVariableStore(VariableStore(url: variableURL))
        await controller.loadPlugins(directories: [pluginsDir], character: "test")

        try await controller.dispatchCommand("save-reload")

        let snapshot = await engine.variablesSnapshot()
        #expect(snapshot["com.test.save-reload"]?["saved_marker"] == "yes")
        let store = VariableStore(url: variableURL)
        try await store.load()
        #expect(await store.scopes["com.test.save-reload"]?["saved_marker"] == "yes")
    }

    @Test("mapper findpath broadcast reaches the calling plugin")
    func mapperFindPathBroadcastReturnsToPlugin() async throws {
        let pluginsDir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let xml = """
        <muclient>
        <plugin id="com.test.mapper-probe" name="Mapper Probe" save_state="y"/>
        <aliases>
          <alias match="^probe-path$" enabled="y" regexp="y" send_to="12">
            <send>CallPlugin("b6eae87ccedd84f510b74714", "findpath", "2", "3", true, true)</send>
          </alias>
        </aliases>
        <script><![CDATA[
        function OnPluginBroadcast(msg, id, name, text)
          if tonumber(msg) == 502 and id == "b6eae87ccedd84f510b74714" then
            SetVariable("path_broadcast", text)
          end
        end
        ]]></script>
        </muclient>
        """
        try xml.write(
            to: pluginsDir.appendingPathComponent("mapper-probe.xml"),
            atomically: true,
            encoding: .utf8
        )
        let mapperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-probe-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: mapperURL) }
        let mapper = try Mapper(store: MapperStore(url: mapperURL))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"z","name":"Z"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Three","zone":"z","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Two","zone":"z","exits":{"n":3}}"#
        )

        let engine = try ScriptEngine()
        let controller = SessionController(scriptEngine: engine)
        await controller.attachMapper(mapper)
        await controller.loadPlugins(directories: [pluginsDir], character: "test")

        try await controller.dispatchCommand("probe-path")

        let snapshot = await engine.variablesSnapshot()
        #expect(snapshot["com.test.mapper-probe"]?["path_broadcast"] ==
            #"found_paths = { { dir = "n", uid = "3" } }"#)
    }

    @Test("native mapper goto broadcasts path results to loaded plugins once")
    func mapperGotoBroadcastsToPlugin() async throws {
        let pluginsDir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: pluginsDir) }
        let xml = """
        <muclient>
        <plugin id="com.test.mapper-monitor-probe" name="Mapper Monitor Probe" save_state="y"/>
        <script><![CDATA[
        function OnPluginInstall()
          SetVariable("count500", "0")
          SetVariable("count501", "0")
          SetVariable("count502", "0")
        end

        function bump(name)
          SetVariable(name, tostring((tonumber(GetVariable(name)) or 0) + 1))
        end

        function OnPluginBroadcast(msg, id, name, text)
          if id ~= "b6eae87ccedd84f510b74714" then return end
          if tonumber(msg) == 500 then
            bump("count500")
            SetVariable("found_text", text)
          elseif tonumber(msg) == 501 then
            bump("count501")
          elseif tonumber(msg) == 502 then
            bump("count502")
          end
        end
        ]]></script>
        </muclient>
        """
        try xml.write(
            to: pluginsDir.appendingPathComponent("mapper-monitor-probe.xml"),
            atomically: true,
            encoding: .utf8
        )
        let mapperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-monitor-probe-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: mapperURL) }
        let mapper = try Mapper(store: MapperStore(url: mapperURL))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"z","name":"Z"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Three","zone":"z","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Two","zone":"z","exits":{"n":3}}"#
        )

        let engine = try ScriptEngine()
        let controller = SessionController(scriptEngine: engine)
        await controller.attachMapper(mapper)
        await controller.loadPlugins(directories: [pluginsDir], character: "test")

        try await controller.dispatchCommand("mapper goto 3")

        let snapshot = await engine.variablesSnapshot()
        let scope = snapshot["com.test.mapper-monitor-probe"]
        #expect(scope?["count500"] == "1")
        #expect(scope?["count501"] == "1")
        #expect(scope?["count502"] == "0")
        #expect(scope?["found_text"]?.contains(#"["3"]"#) == true)
    }

    @Test("loadPlugins is a no-op for an empty / missing directory")
    func emptyDirectoryNoOp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = try ScriptEngine()
        let controller = SessionController(scriptEngine: engine)
        await controller.loadPlugins(directories: [directory], character: "test")
        #expect(await engine.triggerList.isEmpty)

        // A directory that doesn't exist is also safe.
        let missing = directory.appendingPathComponent("nope", isDirectory: true)
        await controller.loadPlugins(directories: [missing], character: "test")
        #expect(await engine.triggerList.isEmpty)
    }
}
