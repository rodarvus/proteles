#if os(macOS)
    import Foundation

    /// Zips a plugin's directory for sharing — the "Export…" action. Stages a
    /// copy of the plugin dir **without** its per-character `data/` (so you share
    /// the plugin's code, not your character's DB/state), then `ditto`-zips it.
    /// A recipient unzips and drops the folder into their own `Plugins/`, then
    /// Add Plugin… ▸ From your Mac.
    public enum PluginExporter {
        public enum ExportError: LocalizedError {
            case staging(String)
            case zip(String)

            public var errorDescription: String? {
                switch self {
                case .staging(let detail): "Couldn't prepare the plugin for export: \(detail)"
                case .zip(let detail): "Couldn't create the zip: \(detail)"
                }
            }
        }

        /// Zip `pluginDirectory` (minus `data/`) to `destination` (a `.zip`).
        public static func export(
            pluginDirectory: URL,
            to destination: URL,
            fileManager: FileManager = .default
        ) throws {
            let staging = fileManager.temporaryDirectory
                .appendingPathComponent("plugin-export-\(UUID().uuidString)", isDirectory: true)
            // Stage <staging>/<name>/ so the zip contains a single top-level
            // folder named after the plugin (clean to drop into Plugins/).
            let staged = staging.appendingPathComponent(pluginDirectory.lastPathComponent, isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            do {
                try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
                let items = try fileManager.contentsOfDirectory(
                    at: pluginDirectory, includingPropertiesForKeys: nil
                )
                for item in items where item.lastPathComponent != "data" {
                    try fileManager.copyItem(
                        at: item,
                        to: staged.appendingPathComponent(item.lastPathComponent)
                    )
                }
            } catch {
                throw ExportError.staging(error.localizedDescription)
            }

            try? fileManager.removeItem(at: destination)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            // Zip the staging parent so the archive has a single top-level
            // `<name>/` folder (ditto -c -k of a dir puts its *contents* at the
            // root, so we point it at `staging`, which holds only `<name>/`).
            process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            do {
                try process.run()
            } catch {
                throw ExportError.zip(error.localizedDescription)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                ) ?? "ditto exited \(process.terminationStatus)"
                throw ExportError.zip(message)
            }
        }
    }
#endif
