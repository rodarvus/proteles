import Foundation
@testable import MudCore
import Testing

@Suite("LocalPluginStore — local-plugin references")
struct LocalPluginStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Add + reload round-trips the references through disk")
    func roundTrips() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("local-plugins.json")

        let store = LocalPluginStore(url: url)
        let ref = LocalPluginReference(path: "/Users/me/plugins/mine/mine.xml")
        try await store.add(ref)
        try await store.add(LocalPluginReference(path: "/Users/me/other.xml", enabled: false))

        // A fresh store over the same file sees both, with fields preserved.
        let reloaded = LocalPluginStore(url: url)
        try await reloaded.load()
        let plugins = await reloaded.plugins
        #expect(plugins.count == 2)
        #expect(plugins.first?.path == "/Users/me/plugins/mine/mine.xml")
        #expect(plugins.first?.enabled == true)
        #expect(plugins.last?.enabled == false)
    }

    @Test("setEnabled + remove mutate and persist")
    func setEnabledAndRemove() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("local-plugins.json")
        let store = LocalPluginStore(url: url)
        let ref = LocalPluginReference(path: "/x/y.xml")
        try await store.add(ref)

        try await store.setEnabled(false, id: ref.id)
        #expect(await store.plugins.first?.enabled == false)

        try await store.remove(id: ref.id)
        #expect(await store.plugins.isEmpty)
        // notFound surfaces for an unknown id.
        await #expect(throws: LocalPluginStore.StoreError.self) {
            try await store.remove(id: ref.id)
        }
    }

    @Test("A missing file loads as empty (no file written until first edit)")
    func missingFileIsEmpty() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nope.json")
        let store = LocalPluginStore(url: url)
        try await store.load()
        #expect(await store.plugins.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A document missing the `plugins` key decodes as empty")
    func documentBackwardCompatible() throws {
        let data = Data("{}".utf8)
        let doc = try JSONDecoder().decode(LocalPluginDocument.self, from: data)
        #expect(doc.plugins.isEmpty)
    }

    @Test("resolvePluginXML: a .xml file resolves to itself")
    func resolveXMLFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = dir.appendingPathComponent("plugin.xml")
        try Data("<muclient/>".utf8).write(to: xml)
        #expect(LocalPluginStore.resolvePluginXML(at: xml) == xml)
        // A non-.xml file resolves to nil.
        let txt = dir.appendingPathComponent("readme.txt")
        try Data("hi".utf8).write(to: txt)
        #expect(LocalPluginStore.resolvePluginXML(at: txt) == nil)
    }

    @Test("resolvePluginXML: a folder yields its .xml, preferring a name match")
    func resolveFolder() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A folder named "mine" containing mine.xml + helper.xml → prefers mine.xml.
        let mine = root.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let mineXML = mine.appendingPathComponent("mine.xml")
        try Data("<muclient/>".utf8).write(to: mineXML)
        try Data("<muclient/>".utf8).write(to: mine.appendingPathComponent("helper.xml"))
        try Data("local m={} return m".utf8).write(to: mine.appendingPathComponent("mod.lua"))
        // Compare resolved paths — macOS temp dirs are /var → /private/var symlinks.
        #expect(
            LocalPluginStore.resolvePluginXML(at: mine)?.resolvingSymlinksInPath()
                == mineXML.resolvingSymlinksInPath()
        )

        // A folder with a single (non-matching-name) .xml → that one.
        let solo = root.appendingPathComponent("solo", isDirectory: true)
        try FileManager.default.createDirectory(at: solo, withIntermediateDirectories: true)
        let onlyXML = solo.appendingPathComponent("whatever.xml")
        try Data("<muclient/>".utf8).write(to: onlyXML)
        #expect(
            LocalPluginStore.resolvePluginXML(at: solo)?.resolvingSymlinksInPath()
                == onlyXML.resolvingSymlinksInPath()
        )

        // A folder with no .xml → nil.
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(LocalPluginStore.resolvePluginXML(at: empty) == nil)

        // A path that doesn't exist → nil.
        #expect(LocalPluginStore.resolvePluginXML(at: root.appendingPathComponent("ghost")) == nil)
    }
}
