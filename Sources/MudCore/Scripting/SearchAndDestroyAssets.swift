import Foundation

/// Accessors for the Search-and-Destroy plugin's Lua. S&D (by Crowley) is **not
/// bundled** with Proteles — it's a separate, user-installed download (see
/// ``SearchAndDestroyInstaller``). These accessors read it from the runtime
/// install directory; everything returns `nil` (``isInstalled`` is `false`)
/// until the user installs it. Gammon's `wait`/`check` helpers it also needs
/// are bundled separately (see ``MUSHHelperAssets``).
public enum SearchAndDestroyAssets {
    /// Directory holding the installed S&D Lua. Defaults to the app's plugin
    /// support folder; tests point it at a bundled fixture. Set once at startup
    /// (or by tests), so the unchecked global is acceptable.
    public nonisolated(unsafe) static var installDirectory: URL? = defaultInstallDirectory

    /// `~/Library/Application Support/com.proteles.ProtelesApp/plugins/search-and-destroy`.
    public static var defaultInstallDirectory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        .appendingPathComponent("com.proteles.ProtelesApp/plugins/search-and-destroy", isDirectory: true)
    }

    /// Whether S&D is installed (its `core.lua` is present in the install dir).
    public static var isInstalled: Bool {
        core != nil
    }

    /// The plugin's main script (the original `<script>` CDATA), or nil if not
    /// installed.
    public static var core: String? {
        lua("core")
    }

    /// An installed Lua module's source by name (e.g. `areaReferences`,
    /// `constants`, `sqlSetup`, `tablesSetup`), or nil if not installed.
    public static func lua(_ name: String) -> String? {
        guard let url = installDirectory?.appendingPathComponent("\(name).lua") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The normalised plugin XML (source for the trigger/alias/timer
    /// definitions; parsed by a tolerant extractor since MUSHclient's XML
    /// isn't strict enough for `XMLParser`).
    public static var pluginXML: String? {
        guard let url = installDirectory?.appendingPathComponent("Search_and_Destroy.xml") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// S&D's own data modules to register with the runtime's module loader (so
    /// its `require`s resolve). Gammon's `wait`/`check` are registered
    /// separately from ``MUSHHelperAssets`` (they're bundled, not downloaded).
    public static var helperModules: [String: String] {
        ["constants", "areaReferences", "sqlSetup", "tablesSetup"]
            .reduce(into: [:]) { result, name in result[name] = lua(name) }
    }
}
