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
        /// Resolve at import time: on a fresh install (no configured profiles)
        /// import as the primary profile — reusing an untouched/blank profile if
        /// one exists, else creating one named from the world — so there's no
        /// duplicate/"(imported)" clutter. If a configured profile already exists,
        /// create a separate `importedName` profile so the existing setup isn't
        /// clobbered.
        case adaptive(importedName: String)
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
        switch await resolve(target, world: world, profiles: profiles) {
        case .adaptive:
            preconditionFailure("resolve() never returns .adaptive")

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
            let wasBlank = profile.host.trimmingCharacters(in: .whitespaces).isEmpty
            profile.host = world.host
            profile.port = world.port
            profile.autologin = autologin
            // Name a reused blank from the world; keep a real merge target's name.
            if wasBlank, !world.name.isEmpty { profile.name = world.name }
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

    /// Resolve `.adaptive` to a concrete `.newProfile`/`.merge`; pass others
    /// through. A profile counts as "configured" if it has a non-empty host.
    private static func resolve(
        _ target: Target,
        world: MUSHclientWorldFile,
        profiles: ProfileStore
    ) async -> Target {
        guard case .adaptive(let importedName) = target else { return target }
        let all = await profiles.profiles
        /// "Reusable" = the seeded Aardwolf default or a blank New World the user
        /// hasn't set up (no autologin; default or empty host). A real profile the
        /// user configured (autologin, or a different host) is NOT reusable.
        func reusable(_ profile: WorldProfile) -> Bool {
            let host = profile.host.trimmingCharacters(in: .whitespaces)
            return profile.autologin == nil
                && (host.isEmpty || host == WorldProfile.aardwolfDefault.host)
        }
        if all.contains(where: { !reusable($0) }) { return .newProfile(name: importedName) }
        if let seed = all.first(where: reusable) { return .merge(seed.id) }
        return .newProfile(name: world.name.isEmpty ? "Aardwolf" : world.name)
    }
}
