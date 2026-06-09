import Foundation
@testable import MudCore
import Testing

@Suite("ProfileImporter — adaptive target")
struct ProfileImporterAdaptiveTests {
    /// A fresh store seeds the untouched "Aardwolf" default (aardmud.org).
    private func freshStore() async throws -> ProfileStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worlds-\(UUID().uuidString).json")
        let store = ProfileStore(url: url)
        try await store.load()
        return store
    }

    private let world = MUSHclientWorldFile(
        name: "Aardwolf", host: "aardmud.org", port: 23, username: "hero"
    )

    private func runAdaptive(into store: ProfileStore) async throws -> UUID {
        try await ProfileImporter.apply(
            world: world,
            target: .adaptive(importedName: "Aardwolf (imported)"),
            profiles: store,
            credentials: InMemoryCredentialStore()
        )
    }

    @Test("fresh: the untouched seeded default is reused (populated), not duplicated")
    func reuseSeed() async throws {
        let store = try await freshStore()
        let seedID = try #require(await store.profiles.first?.id)
        let id = try await runAdaptive(into: store)
        #expect(id == seedID) // reused the seed, not a new profile
        #expect(await store.profiles.count == 1) // no "(imported)" duplicate
        let profile = try #require(await store.profiles.first { $0.id == id })
        #expect(profile.autologin?.username == "hero") // now configured by the import
        #expect(profile.port == 23)
    }

    @Test("a configured profile (autologin set) → separate Aardwolf (imported)")
    func separateWhenConfigured() async throws {
        let store = try await freshStore()
        var seed = try #require(await store.profiles.first)
        seed.autologin = Autologin(username: "existing") // user already set it up
        try await store.update(seed)
        let id = try await runAdaptive(into: store)
        #expect(id != seed.id)
        #expect(await store.profiles.count == 2)
        #expect(await store.profiles.first { $0.id == id }?.name == "Aardwolf (imported)")
        #expect(await store.profiles.first { $0.id == seed.id }?.autologin?.username == "existing")
    }
}
