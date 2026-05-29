import Foundation
@testable import MudCore
import Testing

@Suite("PluginInstaller — .xml resolution")
struct PluginResolveTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("resolvePluginXML: a .xml file resolves to itself; a non-.xml to nil")
    func resolveXMLFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = dir.appendingPathComponent("plugin.xml")
        try Data("<muclient/>".utf8).write(to: xml)
        #expect(PluginInstaller.resolvePluginXML(at: xml) == xml)
        let txt = dir.appendingPathComponent("readme.txt")
        try Data("hi".utf8).write(to: txt)
        #expect(PluginInstaller.resolvePluginXML(at: txt) == nil)
    }

    @Test("resolvePluginXML: a folder yields its .xml, preferring a name match")
    func resolveFolder() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let mine = root.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let mineXML = mine.appendingPathComponent("mine.xml")
        try Data("<muclient/>".utf8).write(to: mineXML)
        try Data("<muclient/>".utf8).write(to: mine.appendingPathComponent("helper.xml"))
        #expect(
            PluginInstaller.resolvePluginXML(at: mine)?.resolvingSymlinksInPath()
                == mineXML.resolvingSymlinksInPath()
        )

        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(PluginInstaller.resolvePluginXML(at: empty) == nil)
        #expect(PluginInstaller.resolvePluginXML(at: root.appendingPathComponent("ghost")) == nil)
    }

    @Test("findPluginXML descends into a wrapper directory (e.g. a repo zip)")
    func findNestedXML() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Mimic a GitHub repo zip: root/<repo-main>/plugin.xml
        let wrapper = root.appendingPathComponent("repo-main", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        let xml = wrapper.appendingPathComponent("plugin.xml")
        try Data("<muclient/>".utf8).write(to: xml)
        #expect(
            PluginInstaller.findPluginXML(under: root)?.resolvingSymlinksInPath()
                == xml.resolvingSymlinksInPath()
        )
    }

    @Test("A plugin's dofile(GetPluginInfo(id,20)..file) resolves its sibling module")
    func siblingModuleResolves() async throws {
        // GetPluginInfo(id, 20) is the plugin's directory and MUSHclient returns
        // it WITH a trailing separator, so `GetPluginInfo(id,20) .. "x_db.lua"`
        // must land in the folder — not mangle into `<folder><file>`. The fix is
        // SessionController.directoryPath (trailing slash); exercise it (D-58).
        let folder = try tempDir().appendingPathComponent("plug", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"Note("SIB_OK")"#.utf8).write(to: folder.appendingPathComponent("sib.lua"))
        let xml = """
        <muclient><plugin id="aaaaaaaaaaaaaaaaaaaaaaaa" name="SibTest"/>
        <script><![CDATA[
        dofile(GetPluginInfo(GetPluginID(), 20) .. "sib.lua")
        ]]></script>
        </muclient>
        """

        let engine = try ScriptEngine()
        await engine.setModuleSearchPaths([folder.path])
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let context = PluginContext(
            pluginID: plugin.id,
            pluginName: plugin.name,
            pluginDirectory: SessionController.directoryPath(folder),
            worldDirectory: folder.path,
            appDirectory: folder.path
        )
        let effects = await engine.loadPlugin(plugin, context: context)

        let texts = effects.compactMap { effect -> String? in
            switch effect {
            case .echo(let text), .echoAard(let text), .echoAnsi(let text): text
            case .note(let text, _, _): text
            case .colourNote(let segments): segments.map(\.text).joined()
            default: nil
            }
        }
        #expect(
            !texts.contains { $0.lowercased().contains("cannot open") },
            "the sibling dofile must resolve (no open failure); got \(texts)"
        )
        #expect(
            texts.contains { $0.contains("SIB_OK") },
            "the dofile'd sibling must run — GetPluginInfo(id,20) must end in a separator"
        )
    }
}
