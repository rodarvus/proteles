import Foundation
@testable import MudCore
import Testing

@Suite("PluginLibrary — registry store")
struct PluginLibraryTests {
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-library-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("plugin-library.json")
    }

    private func entry(
        _ id: String,
        name: String = "Plugin",
        origin: PluginOrigin = .file(path: "/tmp/x.xml"),
        enabledFor profiles: Set<UUID> = []
    ) -> PluginLibraryEntry {
        PluginLibraryEntry(
            pluginID: id, name: name, dirName: name, origin: origin, enabledProfiles: profiles
        )
    }

    @Test("A missing registry file loads as empty")
    func loadMissingIsEmpty() async throws {
        let store = PluginLibraryStore(url: tempStoreURL())
        try await store.load()
        #expect(await store.entries.isEmpty)
    }

    @Test("upsert adds, then replaces an entry with the same plugin id (no duplicate)")
    func upsertDeduplicatesByID() async throws {
        let store = PluginLibraryStore(url: tempStoreURL())
        try await store.upsert(entry("abc", name: "First"))
        try await store.upsert(entry("def", name: "Other"))
        try await store.upsert(entry("abc", name: "Renamed"))
        let entries = await store.entries
        #expect(entries.count == 2)
        #expect(entries.first { $0.pluginID == "abc" }?.name == "Renamed")
    }

    @Test("setEnabled toggles per-profile membership; enabled(forProfile:) filters")
    func enablementIsPerProfile() async throws {
        let store = PluginLibraryStore(url: tempStoreURL())
        let p1 = UUID(), p2 = UUID()
        try await store.upsert(entry("abc"))
        try await store.setEnabled(true, pluginID: "abc", forProfile: p1)

        #expect(await store.enabled(forProfile: p1).map(\.pluginID) == ["abc"])
        #expect(await store.enabled(forProfile: p2).isEmpty)

        try await store.setEnabled(false, pluginID: "abc", forProfile: p1)
        #expect(await store.enabled(forProfile: p1).isEmpty)
    }

    @Test("recordUpdate replaces origin and stamps updatedAt")
    func recordUpdateRewritesOrigin() async throws {
        let store = PluginLibraryStore(url: tempStoreURL())
        try await store.upsert(entry("abc", origin: .file(path: "/old.xml")))
        let when = Date(timeIntervalSince1970: 1000)
        try await store.recordUpdate(pluginID: "abc", origin: .url("https://example.test/p.zip"), at: when)
        let updated = await store.entries.first
        #expect(updated?.origin == .url("https://example.test/p.zip"))
        #expect(updated?.updatedAt == when)
    }

    @Test("remove deletes the entry; mutating a missing id throws notFound")
    func removeAndMissing() async throws {
        let store = PluginLibraryStore(url: tempStoreURL())
        try await store.upsert(entry("abc"))
        try await store.remove(pluginID: "abc")
        #expect(await store.entries.isEmpty)

        await #expect(throws: PluginLibraryStore.StoreError.notFound("abc")) {
            try await store.remove(pluginID: "abc")
        }
    }

    @Test("the registry round-trips through disk")
    func persistsAcrossReload() async throws {
        let url = tempStoreURL()
        let p1 = UUID()
        let writer = PluginLibraryStore(url: url)
        try await writer.upsert(entry("abc", name: "Quest Helper", enabledFor: [p1]))

        let reader = PluginLibraryStore(url: url)
        try await reader.load()
        let loaded = await reader.entries
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Quest Helper")
        #expect(loaded.first?.isEnabled(forProfile: p1) == true)
    }

    @Test("a document JSON with no entries key decodes as empty")
    func documentBackwardCompatibleDecode() throws {
        let doc = try JSONDecoder().decode(PluginLibraryDocument.self, from: Data("{}".utf8))
        #expect(doc.entries.isEmpty)
    }
}

@Suite("ProtelesPaths — directory slug")
struct ProtelesPathsTests {
    @Test("path-hostile characters are replaced; readable names are kept")
    func slugSanitises() {
        #expect(ProtelesPaths.directorySlug(for: "Quest Helper") == "Quest Helper")
        #expect(ProtelesPaths.directorySlug(for: "a/b:c") == "a-b-c")
        #expect(ProtelesPaths.directorySlug(for: "   ") == "Plugin")
        #expect(ProtelesPaths.directorySlug(for: "") == "Plugin")
    }
}
