import Foundation

/// Write phase (P2): install the selected third-party ("offer") plugins into the
/// library — copied into `Plugins/<name>/`, registered, enabled for the imported
/// profile — and seed each one's saved state into the variable store so it
/// resumes where MUSHclient left off. `package`/`bundled` plugins are not
/// installed here (Proteles provides the code; their data comes via the
/// database/state import). Failures are collected, never fatal (→ report path).
public enum MUSHclientPluginImporter {
    /// The stores + target the install writes into.
    public struct Environment {
        public var profile: UUID
        public var pluginsDirectory: URL
        public var library: PluginLibraryStore
        public var variables: VariableStore
        public var now: Date

        public init(
            profile: UUID,
            pluginsDirectory: URL,
            library: PluginLibraryStore,
            variables: VariableStore,
            now: Date
        ) {
            self.profile = profile
            self.pluginsDirectory = pluginsDirectory
            self.library = library
            self.variables = variables
            self.now = now
        }
    }

    public static func apply(
        plugins: [ImportManifest.PluginEntry],
        stateFiles: [ImportManifest.StateFile],
        into env: Environment
    ) async throws -> [ImportManifest.Problem] {
        var problems: [ImportManifest.Problem] = []
        let stateByID = Dictionary(stateFiles.map { ($0.pluginID, $0.variables) }) { first, _ in first }

        for entry in plugins where entry.classification == .offer {
            guard let copyRoot = entry.copyRoot else {
                problems.append(.init(item: entry.include, reason: "No files to import"))
                continue
            }
            do {
                let result = try PluginInstaller.installFromFiles(
                    [copyRoot],
                    into: env.pluginsDirectory,
                    enabledFor: env.profile,
                    now: env.now
                )
                try await env.library.upsert(result.entry)
                copySidecars(entry.pluginDirSidecars, into: result.directory)
                if let id = entry.pluginID, let vars = stateByID[id], !vars.isEmpty {
                    try await env.variables.update(scope: id, variables: vars)
                }
            } catch {
                problems.append(.init(
                    item: entry.include,
                    reason: "Install failed: \(error.localizedDescription)"
                ))
            }
        }
        return problems
    }

    /// Copy code-referenced sidecar files (e.g. a gag list read via
    /// `GetInfo(56)`) into the plugin's installed folder, where Proteles' GetInfo
    /// maps the plugin's app dir. Best-effort: a copy failure is non-fatal.
    private static func copySidecars(_ files: [URL], into directory: URL) {
        let fileManager = FileManager.default
        for file in files {
            let destination = directory.appendingPathComponent(file.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: file, to: destination)
        }
    }
}
