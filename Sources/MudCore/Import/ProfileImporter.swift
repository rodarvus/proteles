import Foundation

/// Write phase (P2): apply a scanned MUSHclient world's connection config to a
/// Proteles profile — either a new profile or merged into an existing one — and
/// route the autologin password into the credential store.
///
/// The password comes straight off the parsed ``MUSHclientWorldFile/password``
/// into the Keychain (keyed by the profile id); it never passes through the
/// manifest, a log, or any tracked file.
public enum ProfileImporter {
    public enum Target: Sendable, Equatable {
        /// Create a fresh profile with this display name.
        case newProfile(name: String)
        /// Merge the world's connection config into an existing profile.
        case merge(UUID)
    }

    public enum ImportError: Error, Equatable {
        case profileNotFound(UUID)
    }

    /// Apply the world's connection config + autologin. Returns the profile id.
    @discardableResult
    public static func apply(
        world: MUSHclientWorldFile,
        target: Target,
        profiles: ProfileStore,
        credentials: some CredentialStore
    ) async throws -> UUID {
        let username = world.username.trimmingCharacters(in: .whitespaces)
        let autologin = username.isEmpty ? nil : Autologin(username: username)

        let profileID: UUID
        switch target {
        case .newProfile(let name):
            let profile = WorldProfile(
                name: name,
                host: world.host,
                port: world.port,
                encoding: .utf8,
                autoconnect: false,
                autologin: autologin,
                transport: .direct
            )
            profileID = profile.id
            try await profiles.add(profile)

        case .merge(let id):
            guard var profile = await profiles.profiles.first(where: { $0.id == id }) else {
                throw ImportError.profileNotFound(id)
            }
            profile.host = world.host
            profile.port = world.port
            profile.autologin = autologin
            profileID = id
            try await profiles.update(profile)
        }

        // Autologin password → Keychain (only here; never logged or in the manifest).
        if let password = world.password, !password.isEmpty {
            credentials.setPassword(
                password, forAccount: Autologin.passwordAccount(for: profileID)
            )
        }
        return profileID
    }
}
