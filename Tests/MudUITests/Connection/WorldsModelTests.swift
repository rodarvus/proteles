import Foundation
import MudCore
@testable import MudUI
import Testing

@Suite("WorldsModel", .serialized)
@MainActor
struct WorldsModelTests {
    @Test("load mirrors the seeded store and selects the active profile")
    func loadMirrorsStore() async {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorldsModel(store: ProfileStore(url: url))
        await model.load()

        #expect(model.profiles.count == 1)
        #expect(model.profiles.first?.name == "Aardwolf")
        #expect(model.activeProfile?.host == "aardmud.org")
        #expect(model.selectedID == model.activeProfileID)
    }

    @Test("addProfile appends and selects the new profile")
    func addProfileSelectsNew() async {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorldsModel(store: ProfileStore(url: url))
        await model.load()
        await model.addProfile()

        #expect(model.profiles.count == 2)
        let newID = try? #require(model.selectedID)
        #expect(model.profiles.contains { $0.id == newID })
        #expect(model.profiles.contains { $0.name == "New World" })
    }

    @Test("binding(for:) writes through to the store")
    func bindingWritesThrough() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorldsModel(store: ProfileStore(url: url))
        await model.load()
        let id = try #require(model.selectedID)
        let binding = try #require(model.binding(for: id))

        var edited = binding.wrappedValue
        edited.name = "Renamed"
        edited.port = 4010
        binding.wrappedValue = edited

        // In-memory reflects immediately.
        #expect(model.profiles.first { $0.id == id }?.name == "Renamed")

        // Persisted: reload a fresh model from the same file.
        // Give the write-through Task a moment to land.
        try await Task.sleep(for: .milliseconds(50))
        let reloaded = WorldsModel(store: ProfileStore(url: url))
        await reloaded.load()
        #expect(reloaded.profiles.first { $0.id == id }?.name == "Renamed")
        #expect(reloaded.profiles.first { $0.id == id }?.port == 4010)
    }

    @Test("setActive updates the active pointer")
    func setActiveUpdates() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorldsModel(store: ProfileStore(url: url))
        await model.load()
        await model.addProfile()
        let newID = try #require(model.selectedID)

        await model.setActive(newID)
        #expect(model.activeProfileID == newID)
        #expect(model.activeProfile?.id == newID)
    }

    @Test("removeSelected drops the profile and re-selects")
    func removeSelectedReselects() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorldsModel(store: ProfileStore(url: url))
        await model.load()
        await model.addProfile()
        let newID = try #require(model.selectedID)

        await model.removeSelected()
        #expect(!model.profiles.contains { $0.id == newID })
        #expect(model.profiles.count == 1)
        // Selection landed on a still-present profile.
        #expect(model.profiles.contains { $0.id == model.selectedID })
    }

    @Test("binding(for:) returns nil for unknown id")
    func bindingNilForUnknown() async {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorldsModel(store: ProfileStore(url: url))
        await model.load()
        #expect(model.binding(for: UUID()) == nil)
    }
}

private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "proteles-worldsmodel-test-\(UUID().uuidString).json"
    )
}
