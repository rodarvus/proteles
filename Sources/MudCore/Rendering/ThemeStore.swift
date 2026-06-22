import Foundation

/// Hand-editable user themes stored under `Settings/themes.json`.
public struct UserThemeCollection: SettingsFileBacked, Equatable {
    public static let settingsFileName = "themes.json"

    public var themes: [Theme]

    public init(themes: [Theme] = []) {
        self.themes = themes
    }

    public init() {
        themes = []
    }

    func sanitized() -> UserThemeCollection {
        var seen = Set<String>()
        let valid = themes.filter { theme in
            guard theme.id.hasPrefix("user."),
                  !Theme.isBuiltIn(id: theme.id),
                  !seen.contains(theme.id),
                  Self.isComplete(theme.palette)
            else { return false }
            seen.insert(theme.id)
            return true
        }
        return UserThemeCollection(themes: valid)
    }

    private static func isComplete(_ palette: ColorPalette) -> Bool {
        NamedColor.allCases.allSatisfy { palette.named[$0] != nil && palette.brightNamed[$0] != nil }
    }
}

/// Process-wide user-theme catalog. Synchronous and lock-backed so existing
/// theme resolution can stay value-based (`Theme.with(id:)`) across UI surfaces.
public final class ThemeStore: @unchecked Sendable {
    public static let shared = ThemeStore()

    private let lock = NSLock()
    private var collection = UserThemeCollection()
    private var url: URL?

    private init() {}

    public var themes: [Theme] {
        lock.lock()
        defer { lock.unlock() }
        return collection.themes
    }

    public func load(from url: URL? = try? UserThemeCollection.defaultURL()) {
        let loaded = UserThemeCollection.load(from: url).sanitized()
        lock.lock()
        self.url = url
        collection = loaded
        lock.unlock()
        loaded.save(to: url)
    }

    public func upsert(_ theme: Theme) {
        guard theme.id.hasPrefix("user."), !Theme.isBuiltIn(id: theme.id) else { return }
        lock.lock()
        if let index = collection.themes.firstIndex(where: { $0.id == theme.id }) {
            collection.themes[index] = theme
        } else {
            collection.themes.append(theme)
        }
        let snapshot = collection.sanitized()
        collection = snapshot
        let url = url
        lock.unlock()
        snapshot.save(to: url)
    }

    public func delete(id: String) {
        lock.lock()
        collection.themes.removeAll { $0.id == id }
        let snapshot = collection
        let url = url
        lock.unlock()
        snapshot.save(to: url)
    }

    public func duplicateTheme(id: String, named requestedName: String? = nil) -> Theme {
        var copy = Theme.with(id: id)
        copy.id = "user.\(UUID().uuidString.lowercased())"
        copy.name = uniqueName(requestedName ?? "\(copy.name) Copy")
        upsert(copy)
        return copy
    }

    public func isUserTheme(id: String) -> Bool {
        themes.contains { $0.id == id }
    }

    private func uniqueName(_ baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Custom Theme" : trimmed
        let names = Set(Theme.all.map(\.name))
        guard names.contains(base) else { return base }
        for index in 2...999 {
            let candidate = "\(base) \(index)"
            if !names.contains(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(4))"
    }
}
