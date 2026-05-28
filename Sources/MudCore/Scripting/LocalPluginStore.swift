import Foundation

/// A reference to a **personal** MUSHclient plugin the user pointed Proteles at
/// on their own disk. Unlike imported plugins (copied into the app-support
/// plugins folder), a local plugin is loaded **in place** from the user's
/// chosen path and only a reference is stored — so it never lands in the app
/// bundle or any shared/synced location. Persisted per-world by
/// ``LocalPluginStore``.
public struct LocalPluginReference: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The absolute path the user chose: a plugin `.xml` or the folder holding
    /// it (resolved to the `.xml` by ``LocalPluginStore/resolvePluginXML(at:fileManager:)``).
    public var path: String
    /// Whether this plugin loads for the world (a per-world toggle).
    public var enabled: Bool

    public init(id: UUID = UUID(), path: String, enabled: Bool = true) {
        self.id = id
        self.path = path
        self.enabled = enabled
    }

    /// The on-disk URL the user chose.
    public var url: URL {
        URL(fileURLWithPath: path)
    }
}

/// The persisted set of a world's local-plugin references — one JSON
/// document per profile, mirroring ``ScriptDocument``.
public struct LocalPluginDocument: Codable, Sendable, Equatable {
    public var plugins: [LocalPluginReference]

    public init(plugins: [LocalPluginReference] = []) {
        self.plugins = plugins
    }

    private enum CodingKeys: String, CodingKey {
        case plugins
    }

    /// A missing `plugins` key decodes as empty rather than failing the load
    /// (so a file written before a field existed still opens). Encoding stays
    /// synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugins = try container.decodeIfPresent([LocalPluginReference].self, forKey: .plugins) ?? []
    }
}

/// Actor owning a world's local-plugin references and persisting them to
/// disk, mirroring ``ScriptStore``: the whole document is rewritten atomically
/// after each change (the set is small and edited rarely). Storage only — the
/// session loads the referenced plugins at connect time.
public actor LocalPluginStore {
    public enum StoreError: Error, Equatable {
        case loadFailed(String)
        case saveFailed(String)
        case notFound(UUID)
    }

    /// On-disk path of this world's local-plugin document.
    public let url: URL

    public private(set) var plugins: [LocalPluginReference] = []

    public init(url: URL) {
        self.url = url
    }

    /// A snapshot of the current document.
    public var document: LocalPluginDocument {
        LocalPluginDocument(plugins: plugins)
    }

    // MARK: - Load / mutate

    /// Load the document from disk. A missing file is treated as an empty set
    /// (nothing is written until the first edit).
    public func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            plugins = []
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.loadFailed(error.localizedDescription)
        }
        do {
            plugins = try JSONDecoder().decode(LocalPluginDocument.self, from: data).plugins
        } catch {
            throw StoreError.loadFailed(error.localizedDescription)
        }
    }

    public func add(_ reference: LocalPluginReference) throws {
        plugins.append(reference)
        try persist()
    }

    public func remove(id: UUID) throws {
        guard plugins.contains(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        plugins.removeAll { $0.id == id }
        try persist()
    }

    public func setEnabled(_ enabled: Bool, id: UUID) throws {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        plugins[index].enabled = enabled
        try persist()
    }

    // MARK: - Disk

    /// Per-profile location:
    /// `~/Library/Application Support/com.proteles.ProtelesApp/plugins/<id>/local-plugins.json`
    /// — alongside the world's imported plugins (the loader scans that folder
    /// for `.xml`, so the `.json` is ignored there). Creates the dir if needed.
    public static func defaultStoreURL(
        forProfile id: UUID,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw StoreError.loadFailed("no Application Support directory") }
        let folder = support
            .appendingPathComponent("com.proteles.ProtelesApp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("local-plugins.json")
    }

    /// Resolve a user-chosen path to the plugin `.xml` to load. A `.xml` file is
    /// returned as-is; a folder yields the `.xml` inside — preferring one whose
    /// name matches the folder (`foo/foo.xml`), else the only/first `.xml`.
    /// Returns `nil` if no plugin `.xml` is found.
    public static func resolvePluginXML(at url: URL, fileManager: FileManager = .default) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            return url.pathExtension.lowercased() == "xml" ? url : nil
        }
        let xmls = ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let folderName = url.lastPathComponent.lowercased()
        return xmls.first { $0.deletingPathExtension().lastPathComponent.lowercased() == folderName }
            ?? xmls.first
    }

    private func persist() throws {
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
