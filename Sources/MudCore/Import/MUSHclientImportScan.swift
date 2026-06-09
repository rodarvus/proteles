import Foundation

/// Entry point for scanning a MUSHclient install directory: finds the world
/// file(s), parses the primary one, and produces the full ``ImportManifest``.
/// The app calls this after the user picks a folder (or after unzipping a `.zip`
/// to a temp dir). Pure (filesystem read only).
public enum MUSHclientImportScan {
    public enum ScanError: Error, Equatable {
        case noWorldFile
    }

    /// The scanned world + manifest, plus the other world files found (so the UI
    /// can offer a choice when an install has several, e.g. `Aardwolf.mcl` and
    /// `Aardwolf_no_visuals.mcl`).
    public struct Scan: Sendable {
        public var world: MUSHclientWorldFile
        public var manifest: ImportManifest
        /// Display names of all `.mcl` files found (the primary first).
        public var worldFileNames: [String]
    }

    /// Scan an install rooted anywhere above its `worlds/` directory. Picks the
    /// world file with the most enabled plugins as the primary.
    public static func scan(installRoot: URL, fileManager: FileManager = .default) throws -> Scan {
        let worldFiles = mclFiles(under: installRoot, fileManager: fileManager)
        guard !worldFiles.isEmpty else { throw ScanError.noWorldFile }

        let parsed = worldFiles.compactMap { url -> (URL, MUSHclientWorldFile)? in
            guard let data = try? Data(contentsOf: url),
                  let world = MUSHclientWorldParser.parse(data) else { return nil }
            return (url, world)
        }
        guard let primary = parsed.max(by: { $0.1.pluginIncludes.count < $1.1.pluginIncludes.count })
        else { throw ScanError.noWorldFile }

        // root = the directory containing `worlds/` (the .mcl lives in worlds/).
        let root = primary.0.deletingLastPathComponent().deletingLastPathComponent()
        let manifest = MUSHclientInstallScanner.scan(root: root, world: primary.1)
        let names = ([primary.0] + worldFiles.filter { $0 != primary.0 }).map(\.lastPathComponent)
        return Scan(world: primary.1, manifest: manifest, worldFileNames: names)
    }

    /// All `.mcl` files under `root` (recursive).
    private static func mclFiles(under root: URL, fileManager: FileManager) -> [URL] {
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "mcl" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}
