import Foundation
@testable import MudCore
import Testing

@Suite("ProfileStore — seeding and load", .serialized)
struct ProfileStoreSeedingTests {
    @Test("Loading a nonexistent file seeds the Aardwolf default and writes it")
    func loadSeedsWhenMissing() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        try await store.load()

        let profiles = await store.profiles
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Aardwolf")

        let active = await store.activeProfile
        #expect(active?.host == "aardmud.org")

        // The seed was written to disk so a re-load is stable.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Reloading an existing file restores profiles and active pointer")
    func reloadRestoresState() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let extra = WorldProfile(name: "Test World", host: "example.com", port: 4040)
        do {
            let store = ProfileStore(url: url)
            try await store.load()
            try await store.add(extra)
            try await store.setActive(id: extra.id)
        }

        let reopened = ProfileStore(url: url)
        try await reopened.load()
        let profiles = await reopened.profiles
        #expect(profiles.count == 2)
        let active = await reopened.activeProfile
        #expect(active?.id == extra.id)
    }
}

@Suite("ProfileStore — CRUD", .serialized)
struct ProfileStoreCRUDTests {
    @Test("add appends and persists")
    func addPersists() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        try await store.load()
        let extra = WorldProfile(name: "Other", host: "other.org", port: 23)
        try await store.add(extra)

        let reopened = ProfileStore(url: url)
        try await reopened.load()
        let names = await reopened.profiles.map(\.name).sorted()
        #expect(names == ["Aardwolf", "Other"])
    }

    @Test("update replaces by id and persists")
    func updatePersists() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        try await store.load()
        var aardwolf = try #require(await store.profiles.first)
        aardwolf.port = 4010
        aardwolf.useTLS = true
        try await store.update(aardwolf)

        let reopened = ProfileStore(url: url)
        try await reopened.load()
        let restored = try #require(await reopened.profiles.first)
        #expect(restored.port == 4010)
        #expect(restored.useTLS)
    }

    @Test("update on unknown id throws notFound")
    func updateUnknownThrows() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        try await store.load()
        let ghost = WorldProfile(name: "Ghost", host: "g", port: 1)
        do {
            try await store.update(ghost)
            Issue.record("expected notFound")
        } catch let error as ProfileStore.StoreError {
            #expect(error == .notFound(ghost.id))
        }
    }

    @Test("remove drops the profile and persists")
    func removePersists() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        try await store.load()
        let extra = WorldProfile(name: "Doomed", host: "d", port: 1)
        try await store.add(extra)
        try await store.remove(id: extra.id)

        let reopened = ProfileStore(url: url)
        try await reopened.load()
        let names = await reopened.profiles.map(\.name)
        #expect(names == ["Aardwolf"])
    }

    @Test("Removing the active profile falls back to the first remaining")
    func removeActiveFallsBack() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        try await store.load()
        let aardwolfID = try #require(await store.activeProfileID)
        let extra = WorldProfile(name: "Backup", host: "b", port: 1)
        try await store.add(extra)

        // Aardwolf is active; remove it.
        try await store.remove(id: aardwolfID)
        let active = await store.activeProfile
        #expect(active?.id == extra.id)
    }

    @Test("Removing the last profile clears the active pointer")
    func removeLastClearsActive() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        try await store.load()
        let onlyID = try #require(await store.activeProfileID)
        try await store.remove(id: onlyID)

        let active = await store.activeProfileID
        #expect(active == nil)
        let profiles = await store.profiles
        #expect(profiles.isEmpty)
    }

    @Test("setActive on unknown id throws notFound")
    func setActiveUnknownThrows() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ProfileStore(url: url)
        try await store.load()
        let bogus = UUID()
        do {
            try await store.setActive(id: bogus)
            Issue.record("expected notFound")
        } catch let error as ProfileStore.StoreError {
            #expect(error == .notFound(bogus))
        }
    }
}

@Suite("ProfileDocument — Codable")
struct ProfileDocumentCodableTests {
    @Test("seeded document round-trips")
    func seededRoundTrip() throws {
        let document = ProfileDocument.seeded
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ProfileDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.profiles.count == 1)
        #expect(decoded.activeProfileID == decoded.profiles.first?.id)
    }

    @Test("empty document round-trips with nil active pointer")
    func emptyRoundTrip() throws {
        let document = ProfileDocument()
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ProfileDocument.self, from: data)
        #expect(decoded.profiles.isEmpty)
        #expect(decoded.activeProfileID == nil)
    }
}

// MARK: - Helpers

private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "proteles-profiles-test-\(UUID().uuidString).json"
    )
}
