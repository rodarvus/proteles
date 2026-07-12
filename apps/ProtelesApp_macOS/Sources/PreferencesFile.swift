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
        "autoReconnect", "autoRecordSessions", "keepAlive", ScrollbackPreference.key,
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
        importRules()
        export() // canonicalise the files on disk (and create them on first run)
        exportRules()
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
        exportRules()
    }

    // MARK: - Notification rules (their own readable file, #45)

    /// Import `Settings/notification-rules.json` (file wins) into the
    /// `notificationRulesData` preference. A malformed file is ignored (the
    /// existing rules are kept) rather than wiping the user's rules.
    private func importRules() {
        guard let url = try? ProtelesPaths.notificationRulesFile(),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([NotificationRule].self, from: data)
        else { return }
        UserDefaults.standard.set(rules.encoded, forKey: NotificationRulesStorage.key)
    }

    /// Write the current rules to `Settings/notification-rules.json` as
    /// pretty-printed JSON (the opaque `notificationRulesData` is otherwise not
    /// hand-editable).
    private func exportRules() {
        guard let url = try? ProtelesPaths.notificationRulesFile() else { return }
        let data = UserDefaults.standard.data(forKey: NotificationRulesStorage.key) ?? Data()
        let rules = [NotificationRule].decoded(from: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let pretty = try? encoder.encode(rules) else { return }
        try? pretty.write(to: url, options: .atomic)
    }
}
