import Foundation

/// Per-profile enablement for the built-in core features (D-107): the
/// mapper, dinv, leveldb, and Search & Destroy. They've always been
/// load-bearing and always-on; this store lets a profile opt out of any of
/// them — the world load (`ScriptsModel.load`) consults it before attaching
/// each host. A missing file (the default) means everything is enabled.
///
/// Stored hand-editably in `Settings/coreFeatures.json`, keyed by profile id.
public actor CoreFeatureStore {
    public struct Document: Codable, Sendable, Equatable {
        /// Profile UUID string → the feature ids that profile disabled.
        public var disabledByProfile: [String: [String]]

        public init(disabledByProfile: [String: [String]] = [:]) {
            self.disabledByProfile = disabledByProfile
        }
    }

    /// The feature ids this store governs (matching `BuiltInFeatureRow.id`).
    public static let featureIDs: Set<String> = [
        "mapper", "dinv", "leveldb", "search-and-destroy"
    ]

    public nonisolated let url: URL
    private var document = Document()

    public init(url: URL) {
        self.url = url
    }

    public static func defaultStoreURL() throws -> URL {
        try ProtelesPaths.settingsDirectory().appendingPathComponent("coreFeatures.json")
    }

    /// Load the store. A missing file is "nothing disabled" (nothing is
    /// written until the first toggle).
    public func load() {
        guard let data = FileManager.default.contents(atPath: url.path),
              let decoded = try? JSONDecoder().decode(Document.self, from: data)
        else {
            document = Document()
            return
        }
        document = decoded
    }

    /// The features `profile` has disabled.
    public func disabled(forProfile profile: UUID) -> Set<String> {
        Set(document.disabledByProfile[profile.uuidString] ?? [])
    }

    /// Enable/disable one feature for `profile` and persist.
    public func setEnabled(_ enabled: Bool, featureID: String, forProfile profile: UUID) throws {
        var disabled = disabled(forProfile: profile)
        if enabled {
            disabled.remove(featureID)
        } else {
            disabled.insert(featureID)
        }
        if disabled.isEmpty {
            document.disabledByProfile[profile.uuidString] = nil
        } else {
            document.disabledByProfile[profile.uuidString] = disabled.sorted()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Convenience: the disabled set for `profile` from the default store
    /// location (used by the world load).
    public static func disabledFeatures(forProfile profile: UUID) async -> Set<String> {
        guard let url = try? defaultStoreURL() else { return [] }
        let store = CoreFeatureStore(url: url)
        await store.load()
        return await store.disabled(forProfile: profile)
    }
}
