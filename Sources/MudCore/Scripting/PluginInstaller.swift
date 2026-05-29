import Foundation

/// A plugin's self-describing manifest, written as `plugin.json` inside its
/// directory. Makes a plugin dir self-contained for hand-editing and future
/// sharing (the registry, not this file, is the authoritative load list).
public struct PluginManifest: Codable, Sendable, Equatable {
    public var pluginID: String
    public var name: String
    public var origin: PluginOrigin
    public var addedAt: Date?
    public var updatedAt: Date?

    public init(
        pluginID: String,
        name: String,
        origin: PluginOrigin,
        addedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.pluginID = pluginID
        self.name = name
        self.origin = origin
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}

/// Installs a plugin into the library by copying its files into a new
/// self-contained directory under `~/Documents/Proteles/Plugins/<name>/`.
/// Pure file/parse work — it does **not** touch the registry (the caller upserts
/// the returned ``PluginLibraryEntry``) and never loads anything live.
public enum PluginInstaller {
    public enum InstallError: Error, Equatable {
        /// None of the chosen files/folders contained a plugin `.xml`.
        case noPluginXML
        /// The `.xml` didn't parse as a MUSHclient plugin.
        case parseFailed
        case copyFailed(String)
    }

    /// What a successful install produced: the registry entry to upsert and the
    /// directory the plugin now lives in.
    public struct Result: Sendable, Equatable {
        public let entry: PluginLibraryEntry
        public let directory: URL
    }

    /// The manifest file name inside each plugin directory.
    public static let manifestName = "plugin.json"

    /// Install from local sources — a single folder (its contents are copied),
    /// or one-or-more loose files (a multi-file plugin without a directory). The
    /// `.xml` is resolved among them (a folder prefers `folder/folder.xml`, loose
    /// files prefer the one whose name matches the folder/first, else the only
    /// `.xml`). Copies everything into a fresh `Plugins/<name>/` dir, writes the
    /// manifest, and returns the entry (enabled for `profile`).
    public static func installFromFiles(
        _ sources: [URL],
        into pluginsDirectory: URL,
        enabledFor profile: UUID,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> Result {
        let (items, xml) = try resolve(sources, fileManager: fileManager)
        guard let plugin = (try? Data(contentsOf: xml)).flatMap({ try? MUSHclientPluginLoader.parse($0) })
        else { throw InstallError.parseFailed }
        let name = plugin.name.isEmpty ? xml.deletingPathExtension().lastPathComponent : plugin.name

        let directory = try freshDirectory(for: name, in: pluginsDirectory, fileManager: fileManager)
        do {
            for item in items {
                let destination = directory.appendingPathComponent(item.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: item, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw InstallError.copyFailed(error.localizedDescription)
        }

        let origin = PluginOrigin.file(path: (sources.first ?? xml).path)
        let manifest = PluginManifest(pluginID: plugin.id, name: name, origin: origin, addedAt: now)
        try writeManifest(manifest, into: directory, fileManager: fileManager)
        let entry = PluginLibraryEntry(
            pluginID: plugin.id,
            name: name,
            dirName: directory.lastPathComponent,
            origin: origin,
            enabledProfiles: [profile],
            addedAt: now
        )
        return Result(entry: entry, directory: directory)
    }

    // MARK: - Helpers

    /// Resolve `sources` to (the items to copy, the plugin `.xml`).
    private static func resolve(
        _ sources: [URL], fileManager: FileManager
    ) throws -> (items: [URL], xml: URL) {
        if sources.count == 1, isDirectory(sources[0], fileManager) {
            let folder = sources[0]
            guard let xml = LocalPluginStore.resolvePluginXML(at: folder, fileManager: fileManager)
            else { throw InstallError.noPluginXML }
            let contents = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            )) ?? []
            return (contents, xml)
        }
        let files = sources.filter { !isDirectory($0, fileManager) }
        let xmls = files
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let xml = xmls.first else { throw InstallError.noPluginXML }
        return (files, xml)
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// A fresh, unique `<pluginsDirectory>/<slug>/` directory (appends `-2`,
    /// `-3`… if a dir with that name already exists), created on disk.
    private static func freshDirectory(
        for name: String, in pluginsDirectory: URL, fileManager: FileManager
    ) throws -> URL {
        let base = ProtelesPaths.directorySlug(for: name)
        var candidate = base
        var suffix = 2
        while fileManager.fileExists(atPath: pluginsDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        let directory = pluginsDirectory.appendingPathComponent(candidate, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func writeManifest(
        _ manifest: PluginManifest, into directory: URL, fileManager _: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent(manifestName), options: .atomic)
    }
}
