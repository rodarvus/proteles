import Foundation
@testable import MudCore
import Testing

@Suite("PluginInstaller — local file install")
struct PluginInstallerTests {
    private let fileManager = FileManager.default
    private let now = Date(timeIntervalSince1970: 1000)

    /// A unique temp root with a `src/` (the user's chosen files) and `Plugins/`
    /// (the library destination). Caller cleans up.
    private func makeWorkspace() throws -> (src: URL, plugins: URL) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("installer-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("src", isDirectory: true)
        let plugins = root.appendingPathComponent("Plugins", isDirectory: true)
        try fileManager.createDirectory(at: src, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plugins, withIntermediateDirectories: true)
        return (src, plugins)
    }

    private func writePlugin(
        named file: String, id: String, name: String, in dir: URL
    ) throws -> URL {
        let xml = """
        <muclient><plugin id="\(id)" name="\(name)"/>
        <script><![CDATA[ ]]></script>
        </muclient>
        """
        let url = dir.appendingPathComponent(file)
        try Data(xml.utf8).write(to: url)
        return url
    }

    @Test("Installing a single .xml copies it into a named dir + writes the manifest")
    func installSingleXML() throws {
        let (src, plugins) = try makeWorkspace()
        defer { try? fileManager.removeItem(at: src.deletingLastPathComponent()) }
        let xml = try writePlugin(
            named: "quest.xml",
            id: "aaaaaaaaaaaaaaaaaaaaaaaa",
            name: "Quest Helper",
            in: src
        )

        let result = try PluginInstaller.installFromFiles(
            [xml], into: plugins, enabledFor: UUID(), now: now, fileManager: fileManager
        )

        #expect(result.entry.pluginID == "aaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(result.entry.name == "Quest Helper")
        #expect(result.directory.lastPathComponent == "Quest Helper")
        #expect(fileManager.fileExists(atPath: result.directory.appendingPathComponent("quest.xml").path))
        #expect(result.entry.origin == .file(path: xml.path))

        // Manifest is written and round-trips.
        let manifestData = try Data(contentsOf: result.directory.appendingPathComponent("plugin.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PluginManifest.self, from: manifestData)
        #expect(manifest.pluginID == "aaaaaaaaaaaaaaaaaaaaaaaa")
    }

    @Test("Installing a folder copies all its files; the .xml is resolved")
    func installFolderWithSiblings() throws {
        let (src, plugins) = try makeWorkspace()
        defer { try? fileManager.removeItem(at: src.deletingLastPathComponent()) }
        let folder = src.appendingPathComponent("myplug", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try writePlugin(named: "myplug.xml", id: "bbbbbbbbbbbbbbbbbbbbbbbb", name: "My Plug", in: folder)
        try Data("return {}".utf8).write(to: folder.appendingPathComponent("myplug_db.lua"))

        let result = try PluginInstaller.installFromFiles(
            [folder], into: plugins, enabledFor: UUID(), now: now, fileManager: fileManager
        )

        #expect(fileManager.fileExists(atPath: result.directory.appendingPathComponent("myplug.xml").path))
        #expect(fileManager.fileExists(atPath: result.directory.appendingPathComponent("myplug_db.lua").path))
    }

    @Test("Installing multiple loose files (no directory) copies them all")
    func installLooseFiles() throws {
        let (src, plugins) = try makeWorkspace()
        defer { try? fileManager.removeItem(at: src.deletingLastPathComponent()) }
        let xml = try writePlugin(named: "loose.xml", id: "cccccccccccccccccccccccc", name: "Loose", in: src)
        let lua = src.appendingPathComponent("loose_helper.lua")
        try Data("return {}".utf8).write(to: lua)

        let result = try PluginInstaller.installFromFiles(
            [xml, lua], into: plugins, enabledFor: UUID(), now: now, fileManager: fileManager
        )

        #expect(fileManager.fileExists(atPath: result.directory.appendingPathComponent("loose.xml").path))
        #expect(fileManager
            .fileExists(atPath: result.directory.appendingPathComponent("loose_helper.lua").path))
    }

    @Test("Sources with no .xml throw noPluginXML")
    func noXMLThrows() throws {
        let (src, plugins) = try makeWorkspace()
        defer { try? fileManager.removeItem(at: src.deletingLastPathComponent()) }
        let lua = src.appendingPathComponent("orphan.lua")
        try Data("return {}".utf8).write(to: lua)

        #expect(throws: PluginInstaller.InstallError.noPluginXML) {
            try PluginInstaller.installFromFiles(
                [lua], into: plugins, enabledFor: UUID(), now: now, fileManager: fileManager
            )
        }
    }

    @Test("A second plugin with the same display name gets a unique dir (-2)")
    func nameCollisionUniquifies() throws {
        let (src, plugins) = try makeWorkspace()
        defer { try? fileManager.removeItem(at: src.deletingLastPathComponent()) }
        let first = try writePlugin(named: "a.xml", id: "dddddddddddddddddddddddd", name: "Dup", in: src)
        let second = try writePlugin(named: "b.xml", id: "eeeeeeeeeeeeeeeeeeeeeeee", name: "Dup", in: src)

        let r1 = try PluginInstaller.installFromFiles(
            [first], into: plugins, enabledFor: UUID(), now: now, fileManager: fileManager
        )
        let r2 = try PluginInstaller.installFromFiles(
            [second], into: plugins, enabledFor: UUID(), now: now, fileManager: fileManager
        )
        #expect(r1.directory.lastPathComponent == "Dup")
        #expect(r2.directory.lastPathComponent == "Dup-2")
    }
}
