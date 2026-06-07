import Foundation
import MudCore

/// Mirrors the meaningful app preferences to a hand-editable
/// `~/Documents/Proteles/Settings/preferences.json` (#43).
///
/// The file is **imported into `UserDefaults` at launch** (so a hand-edit applies
/// on the next launch — the file wins) and **written back whenever a managed key
/// changes** (so it always reflects the current settings). `@AppStorage` keeps
/// working unchanged; this is a sync layer, not a rewrite of every binding.
///
/// Only *meaningful* config is mirrored. Transient UI state (window frames,
/// dock layout, first-run flags) stays in `UserDefaults` only. Notification
/// rules are opaque `Data` and aren't mirrored yet (they want their own JSON
/// file — tracked on #43).
@MainActor
final class PreferencesFile {
    static let shared = PreferencesFile()

    /// The simple-typed preference keys to mirror (Bool/Int/Double/String).
    private static let managedKeys: [String] = [
        "themeID", "outputFontName", "outputFontSize",
        "omitBlankLines", "gagTagLines", "richExits",
        "autoReconnect", "autoRecordSessions", "keepAlive",
        "sessionLogging", "sessionLogFormat", "perWorldLogs", "logRetention",
        "notificationsEnabled", "notifyOnTells", "notifyOnMention", "notifyWhenFocused",
        "commandSpellCheck", "inputGhostHint", "navigationMode",
        "chat.timestamps", "chat.timestampSeconds",
        "group.roomOnly", "group.sort",
        "statusBar.health", "statusBar.mana", "statusBar.moves", "statusBar.tnl",
        "statusBar.enemy", "statusBar.align", "statusBar.ticks", "statusBar.numberMode",
        "statusBar.color.health", "statusBar.color.mana", "statusBar.color.moves",
        "statusBar.color.tnl", "statusBar.color.enemy",
        "diagnostics.enabled"
    ]

    private var url: URL? {
        try? ProtelesPaths.preferencesFile()
    }

    private var observer: NSObjectProtocol?
    private var exportScheduled = false

    private init() {}

    /// Import the file (if any) into `UserDefaults`, then keep the file in sync
    /// with subsequent changes. Call once, early in app launch.
    func start() {
        importFromFile()
        export() // canonicalise the file on disk (and create it on first run)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleExport() }
        }
    }

    private func importFromFile() {
        guard let url, let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let defaults = UserDefaults.standard
        for key in Self.managedKeys where dict[key] != nil {
            defaults.set(dict[key], forKey: key)
        }
    }

    /// Coalesce a burst of UserDefaults changes into one write per runloop tick.
    private func scheduleExport() {
        guard !exportScheduled else { return }
        exportScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.exportScheduled = false
            self?.export()
        }
    }

    private func export() {
        guard let url else { return }
        let defaults = UserDefaults.standard
        var dict: [String: Any] = [:]
        for key in Self.managedKeys {
            guard let value = defaults.object(forKey: key),
                  JSONSerialization.isValidJSONObject([value]) else { continue }
            dict[key] = value
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
