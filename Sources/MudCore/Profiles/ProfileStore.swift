import Foundation

/// On-disk collection of ``WorldProfile``s plus a pointer to the
/// currently-active one (PLAN.md §8.4).
///
/// The whole collection lives in one JSON document. That's plenty for
/// the handful of worlds a user realistically configures, keeps the
/// "active profile" pointer transactionally consistent with the
/// profiles themselves, and makes the file trivially inspectable.
public struct ProfileDocument: Codable, Sendable, Equatable {
    public var profiles: [WorldProfile]
    public var activeProfileID: UUID?

    public init(
        profiles: [WorldProfile] = [],
        activeProfileID: UUID? = nil
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }

    /// The starter document a fresh install gets: the single Aardwolf
    /// profile, active.
    public static var seeded: ProfileDocument {
        let aardwolf = WorldProfile.aardwolfDefault
        return ProfileDocument(
            profiles: [aardwolf],
            activeProfileID: aardwolf.id
        )
    }
}

/// Actor that owns the profile collection and persists it to disk.
///
/// Mutations write the whole document back atomically after each
/// change — profile edits are infrequent and the file is small, so
/// there's no value in batching. The view layer (Phase 3 Connection
/// Manager) wraps this in an `@Observable @MainActor` model that
/// mirrors the state for SwiftUI.
public actor ProfileStore {
    public enum StoreError: Error, Equatable {
        case loadFailed(String)
        case saveFailed(String)
        case notFound(UUID)
    }

    /// On-disk path of the profile document.
    public let url: URL

    public private(set) var profiles: [WorldProfile] = []
    public private(set) var activeProfileID: UUID?

    public init(url: URL) {
        self.url = url
    }

    /// The currently-active profile, if any. Resolved from
    /// ``activeProfileID``.
    public var activeProfile: WorldProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    // MARK: - Load / seed

    /// Load the document from disk. If the file does not exist, seed it
    /// with ``ProfileDocument/seeded`` (the single Aardwolf profile)
    /// and write that to disk so subsequent launches are stable.
    public func load() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw StoreError.loadFailed(error.localizedDescription)
            }
            let document: ProfileDocument
            do {
                document = try JSONDecoder().decode(
                    ProfileDocument.self,
                    from: data
                )
            } catch {
                throw StoreError.loadFailed(error.localizedDescription)
            }
            apply(document)
        } else {
            apply(.seeded)
            try persist()
        }
    }

    // MARK: - CRUD

    /// Add a profile. If it's the first profile, it becomes active.
    public func add(_ profile: WorldProfile) throws {
        profiles.append(profile)
        if activeProfileID == nil {
            activeProfileID = profile.id
        }
        try persist()
    }

    /// Replace an existing profile (matched by `id`). Throws
    /// ``StoreError/notFound(_:)`` if no profile has that id.
    public func update(_ profile: WorldProfile) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id })
        else {
            throw StoreError.notFound(profile.id)
        }
        profiles[index] = profile
        try persist()
    }

    /// Remove a profile by id. If it was the active profile, the active
    /// pointer falls back to the first remaining profile (or nil if
    /// none remain).
    public func remove(id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }
        try persist()
    }

    /// Set the active profile by id. Throws if no profile has that id.
    public func setActive(id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        activeProfileID = id
        try persist()
    }

    // MARK: - Disk

    /// Recommended location:
    /// `~/Library/Application Support/com.proteles.ProtelesApp/profiles.json`.
    /// Creates the parent directory if needed.
    public static func defaultStoreURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw StoreError.loadFailed("no Application Support directory")
        }
        let folder = support.appendingPathComponent(
            "com.proteles.ProtelesApp",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return folder.appendingPathComponent("profiles.json")
    }

    // MARK: - Private

    private func apply(_ document: ProfileDocument) {
        profiles = document.profiles
        activeProfileID = document.activeProfileID
    }

    private func persist() throws {
        let document = ProfileDocument(
            profiles: profiles,
            activeProfileID: activeProfileID
        )
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(document)
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
    }
}
