import Foundation
import MudCore
import Observation

/// Drives the MUSHclient import flow for the UI: scan a chosen folder (or `.zip`)
/// off-main, then — on the user's confirmed ``MUSHclientImporter/Selection`` —
/// back up `~/Documents/Proteles` and run the import coordinator. All disk work
/// is off the main actor; results are published back for the review sheet.
@MainActor
@Observable
final class MUSHclientImportModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case review
        case importing
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var scan: MUSHclientImportScan.Scan?
    private(set) var result: MUSHclientImporter.Result?
    /// Where the backup was written (shown after a successful import).
    private(set) var backupURL: URL?

    /// Called after a successful import so the app can reload its world list.
    var onImported: (() -> Void)?

    @ObservationIgnored private var extractedZip: URL?

    // MARK: - Scan

    func beginScan(at url: URL) {
        phase = .scanning
        Task {
            do {
                let root = try await Self.resolveRoot(url)
                var scan = try MUSHclientImportScan.scan(installRoot: root)
                // Don't re-offer plugins already in Proteles' library.
                scan.manifest = await scan.manifest.markingAlreadyInstalled(
                    pluginIDs: Self.installedPluginIDs()
                )
                self.extractedZip = (root != url) ? root : nil
                self.scan = scan
                self.phase = .review
            } catch {
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    // MARK: - Import

    func runImport(selection: MUSHclientImporter.Selection) {
        guard let scan else { return }
        phase = .importing
        Task {
            do {
                let backup = try await Self.backup()
                let environment = try Self.makeEnvironment()
                try await environment.profiles.load()
                try await environment.library.load()
                let result = try await MUSHclientImporter.run(
                    world: scan.world,
                    manifest: scan.manifest,
                    selection: selection,
                    into: environment
                )
                self.backupURL = backup
                self.result = result
                self.phase = .done
                self.onImported?()
            } catch {
                self.phase = .failed(Self.message(for: error))
            }
            self.cleanup()
        }
    }

    func reset() {
        cleanup()
        scan = nil
        result = nil
        backupURL = nil
        phase = .idle
    }

    private func cleanup() {
        if let extractedZip { try? FileManager.default.removeItem(at: extractedZip) }
        extractedZip = nil
    }

    // MARK: - Helpers (off-main-safe statics)

    /// If `url` is a `.zip`, extract it to a temp dir and return that; else return
    /// `url` unchanged.
    private static func resolveRoot(_ url: URL) async throws -> URL {
        guard url.pathExtension.lowercased() == "zip" else { return url }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("mush-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, dest.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ImportModelError.unzipFailed
        }
        return dest
    }

    /// Plugin ids already in Proteles' library (so we don't re-offer them).
    private static func installedPluginIDs() async -> Set<String> {
        guard let url = try? PluginLibraryStore.defaultStoreURL() else { return [] }
        let library = PluginLibraryStore(url: url)
        try? await library.load()
        return await Set(library.entries.map(\.pluginID))
    }

    /// Back up `~/Documents/Proteles` to a timestamped sibling before writing.
    private static func backup() async throws -> URL {
        let home = try ProtelesPaths.home()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = home.deletingLastPathComponent()
            .appendingPathComponent("Proteles-backup-\(stamp)", isDirectory: true)
        if FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.copyItem(at: home, to: backup)
        }
        return backup
    }

    /// Build the coordinator environment from the app's standard locations.
    private static func makeEnvironment() throws -> MUSHclientImporter.Environment {
        let scriptsDirectory = try ProtelesPaths.scriptsDirectory()
        let databasesDirectory = try ProtelesPaths.databasesDirectory()
        let pluginsDirectory = try ProtelesPaths.pluginsDirectory()
        return try MUSHclientImporter.Environment(
            profiles: ProfileStore(url: ProfileStore.defaultStoreURL()),
            credentials: KeychainStore(),
            library: PluginLibraryStore(url: PluginLibraryStore.defaultStoreURL()),
            pluginsDirectory: pluginsDirectory,
            databasesDirectory: databasesDirectory,
            mapImagesDirectory: try? ProtelesPaths.mapImagesDirectory(),
            searchAndDestroyDirectory: SearchAndDestroyAssets.defaultInstallDirectory,
            makeScriptStore: { ScriptStore(directory: scriptsDirectory, character: $0) },
            makeVariableStore: { world in
                let url = (try? ProtelesPaths.variablesFile(world: world.uuidString))
                    ?? scriptsDirectory.appendingPathComponent("vars-\(world.uuidString).json")
                return VariableStore(url: url)
            },
            now: Date()
        )
    }

    private static func message(for error: Error) -> String {
        if let modelError = error as? ImportModelError { return modelError.message }
        if error is MUSHclientImportScan.ScanError {
            return "No MUSHclient world file (.mcl) was found in that folder."
        }
        return error.localizedDescription
    }

    enum ImportModelError: Error {
        case unzipFailed
        var message: String {
            switch self {
            case .unzipFailed: "Couldn't unzip that archive."
            }
        }
    }
}
