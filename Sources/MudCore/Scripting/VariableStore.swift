import Foundation

/// Persisted scoped script/plugin variables for one world (ARCHITECTURE.md §8.7,
/// the ≈ MUSHclient `Get/SetVariable` store). One JSON document per world,
/// keyed `scope → name → value` — where a scope is a plugin id, or the
/// shared `_user` scope for the user's own scripts.
///
/// Storage only, mirroring ``ScriptStore``/``ProfileStore``: the live values
/// live in the ``LuaRuntime`` (read synchronously inside the Lua dispatch);
/// the host hydrates the runtime from here on connect and writes the
/// snapshot back when scopes change or on disconnect. MUSHclient persists a
/// plugin's variables only when it declares `save_state="y"`; the loader
/// decides which scopes to hand this store.
public actor VariableStore {
    public enum StoreError: Error, Equatable {
        case loadFailed(String)
        case saveFailed(String)
    }

    /// On-disk path of this world's variable document.
    public let url: URL

    /// `scope → name → value`.
    public private(set) var scopes: [String: [String: String]] = [:]

    public init(url: URL) {
        self.url = url
    }

    // MARK: - Load / save

    /// Load from disk. A missing file is an empty set (nothing written until
    /// the first save).
    public func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            scopes = [:]
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.loadFailed(error.localizedDescription)
        }
        do {
            scopes = try JSONDecoder().decode([String: [String: String]].self, from: data)
        } catch {
            throw StoreError.loadFailed(error.localizedDescription)
        }
    }

    /// Replace the whole document (e.g. persisting the runtime snapshot) and
    /// write it to disk atomically.
    public func replace(with scopes: [String: [String: String]]) throws {
        self.scopes = scopes
        try persist()
    }

    /// Merge a single scope's variables in and persist. Used when only some
    /// scopes are dirty.
    public func update(scope: String, variables: [String: String]) throws {
        scopes[scope] = variables
        try persist()
    }

    // MARK: - Disk

    /// `~/Documents/Proteles/State/variables/<world-id>.json` (#43).
    public static func defaultStoreURL(
        forProfile id: UUID,
        fileManager: FileManager = .default
    ) throws -> URL {
        try ProtelesPaths.variablesFile(world: id.uuidString, fileManager: fileManager)
    }

    // MARK: - Private

    private func persist() throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(scopes)
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
