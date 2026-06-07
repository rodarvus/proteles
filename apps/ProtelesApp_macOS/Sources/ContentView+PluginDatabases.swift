import AppKit
import MudCore
import MudUI
import SwiftUI
import UniformTypeIdentifiers

/// Import / reset for the plugin-owned SQLite databases (dinv inventory, leveldb
/// leveling history). Split out of ``ContentView`` to keep its body within the
/// type-length budget. These are whole-file **replaces** (the Lua plugins own
/// their schemas, so unlike the mapper/S&D we can't safely merge) done while
/// disconnected — the plugin holds the file open while connected, and the
/// imported DB takes effect on the next connect when the plugin reopens it.
extension ContentView {
    /// The two plugin-owned databases Proteles can import/reset as whole files.
    /// leveldb is one global file; dinv is per-character.
    enum PluginDatabase {
        case dinv
        case levelDB

        var label: String {
            self == .dinv ? "Inventory (dinv)" : "Leveling (leveldb)"
        }

        var fileHint: String {
            self == .dinv ? "dinv.db" : "leveldb.db"
        }
    }

    /// Resolve the on-disk target for `kind` (dinv is found under the active
    /// character's data dir; leveldb is the global path). `nil` ⇒ surface a hint.
    func pluginDatabaseTarget(_ kind: PluginDatabase) async -> URL? {
        switch kind {
        case .levelDB:
            guard let id = worlds.activeProfileID else { return nil }
            let character = await ScriptsModel.characterKey(forProfile: id)
            return try? PluginDatabaseImporter.levelDBTarget(character: character)
        case .dinv:
            guard let id = worlds.activeProfileID else { return nil }
            let character = await ScriptsModel.characterKey(forProfile: id)
            return PluginDatabaseImporter.dinvTarget(character: character)
        }
    }

    /// Import (whole-file replace) a plugin database from a chosen `.db`. Done
    /// while disconnected so the plugin isn't holding the file; takes effect on
    /// the next connect (when the plugin reloads + reopens it).
    func importPluginDatabase(_ kind: PluginDatabase) {
        guard connectionState == .disconnected else {
            Self.infoAlert(
                "Disconnect first",
                "Disconnect before importing the \(kind.label) "
                    + "database — the plugin has it open while you're connected. It takes effect on "
                    + "your next connect."
            )
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a \(kind.label) database (\(kind.fileHint)) to import. "
            + "It replaces the current one."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let accessing = source.startAccessingSecurityScopedResource()
        Task {
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            guard let target = await pluginDatabaseTarget(kind) else {
                Self.infoAlert(
                    "Can't Locate Database",
                    kind == .dinv
                        ? "Connect and run `dinv build` once first so dinv creates its database, then "
                        + "import to replace it."
                        : "Couldn't resolve the leveldb path."
                )
                return
            }
            do {
                try PluginDatabaseImporter.replace(target: target, with: source)
                Self.infoAlert(
                    "\(kind.label) Imported",
                    "Replaced the database. It takes effect on your next connect."
                )
            } catch {
                Self.infoAlert("Import Failed", "That file isn't an SQLite database.")
            }
        }
    }

    /// Delete (reset) a plugin database. The plugin recreates an empty one on its
    /// next load/build. Disconnected-only, like import.
    func resetPluginDatabase(_ kind: PluginDatabase) {
        guard connectionState == .disconnected else {
            Self.infoAlert("Disconnect first", "Disconnect before resetting the \(kind.label) database.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete the \(kind.label) database?"
        alert.informativeText = "This permanently deletes the database file. The plugin recreates "
            + "an empty one on the next connect. For development and testing."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Database")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard let target = await pluginDatabaseTarget(kind) else {
                Self.infoAlert("Nothing to Delete", "No \(kind.label) database was found.")
                return
            }
            do {
                try PluginDatabaseImporter.delete(target: target)
                Self.infoAlert("\(kind.label) Deleted", "The database was removed.")
            } catch {
                Self.infoAlert("Delete Failed", "Couldn't remove the database file.")
            }
        }
    }

    /// A simple modal info alert (these flows run disconnected, where echoing to
    /// the game output wouldn't be seen).
    @MainActor static func infoAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
