import Foundation
@testable import MudCore
import Testing

@Suite("ProfileImporter — connection config + autologin → Keychain")
struct ProfileImporterTests {
    private func store() throws -> ProfileStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imp-\(UUID().uuidString).json")
        return ProfileStore(url: url)
    }

    @Test("new profile: writes host/port/autologin; password lands in the credential store")
    func newProfile() async throws {
        let profiles = try store()
        try await profiles.load()
        let creds = InMemoryCredentialStore()
        let world = MUSHclientWorldFile(
            name: "Aardwolf", host: "aardmud.org", port: 23, username: "hero", password: "s3cret"
        )

        let id = try await ProfileImporter.apply(
            world: world,
            target: .newProfile(name: "Aardwolf (imported)"),
            profiles: profiles,
            credentials: creds
        )

        let profile = try #require(await profiles.profiles.first { $0.id == id })
        #expect(profile.name == "Aardwolf (imported)")
        #expect(profile.host == "aardmud.org")
        #expect(profile.port == 23)
        #expect(profile.autologin?.username == "hero")
        #expect(profile.transport == .direct)
        // Secret routed to the credential store, keyed by profile id.
        #expect(creds.password(forAccount: Autologin.passwordAccount(for: id)) == "s3cret")
    }

    @Test("merge: updates an existing profile's connection config")
    func merge() async throws {
        let profiles = try store()
        try await profiles.load()
        let existing = WorldProfile(name: "My Aardwolf", host: "old", port: 4000)
        try await profiles.add(existing)
        let creds = InMemoryCredentialStore()
        let world = MUSHclientWorldFile(host: "aardmud.org", port: 23, username: "hero")

        let id = try await ProfileImporter.apply(
            world: world, target: .merge(existing.id), profiles: profiles, credentials: creds
        )
        #expect(id == existing.id)
        let profile = try #require(await profiles.profiles.first { $0.id == existing.id })
        #expect(profile.name == "My Aardwolf") // name preserved on merge
        #expect(profile.host == "aardmud.org") // connection updated
        #expect(profile.autologin?.username == "hero")
    }

    @Test("merge into a missing profile throws")
    func mergeMissing() async throws {
        let profiles = try store()
        try await profiles.load()
        await #expect(throws: ProfileImporter.ImportError.self) {
            _ = try await ProfileImporter.apply(
                world: MUSHclientWorldFile(host: "h", port: 23),
                target: .merge(UUID()),
                profiles: profiles,
                credentials: InMemoryCredentialStore()
            )
        }
    }
}
