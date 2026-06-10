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

    /// `~/Documents/Proteles/Plugins/search-and-destroy` (#43) — S&D is a
    /// user-installed download, so it lives in the visible Plugins/ tree with
    /// every other plugin.
    public static var defaultInstallDirectory: URL? {
        try? ProtelesPaths.pluginsDirectory()
            .appendingPathComponent("search-and-destroy", isDirectory: true)
    }

    /// Whether S&D is installed (its plugin XML — the preferred script
    /// source, #53 — or the split `core.lua` is present in the install dir).
    public static var isInstalled: Bool {
        isInstalled(in: installDirectory)
    }

    /// The plugin's main script (the original `<script>` CDATA), or nil if not
    /// installed.
    public static var core: String? {
        core(in: installDirectory)
    }

    /// An installed Lua module's source by name (e.g. `areaReferences`,
    /// `constants`, `sqlSetup`, `tablesSetup`), or nil if not installed.
    public static func lua(_ name: String) -> String? {
        lua(name, in: installDirectory)
    }

    /// The normalised plugin XML (source for the trigger/alias/timer
    /// definitions; parsed by a tolerant extractor since MUSHclient's XML
    /// isn't strict enough for `XMLParser`).
    public static var pluginXML: String? {
        pluginXML(in: installDirectory)
    }

    /// S&D's own data modules to register with the runtime's module loader (so
    /// its `require`s resolve). Gammon's `wait`/`check` are registered
    /// separately from ``MUSHHelperAssets`` (they're bundled, not downloaded).
    public static var helperModules: [String: String] {
        helperModules(in: installDirectory)
    }

    // The accessors above resolve against the shared `installDirectory` global
    // (set once at startup). The `in:` variants below read an explicit
    // directory instead — used by tests so they never touch (and so never race
    // on) the shared global under `swift test --parallel`.

    // MARK: - Directory-injectable accessors

    /// Whether S&D is installed in `directory` (its plugin XML or the split
    /// `core.lua` is present — either can supply the script, #53).
    public static func isInstalled(in directory: URL?) -> Bool {
        pluginXML(in: directory) != nil || core(in: directory) != nil
    }

    /// The plugin's main script read from `directory`, or nil if absent.
    public static func core(in directory: URL?) -> String? {
        lua("core", in: directory)
    }

    /// An installed Lua module's source read from `directory`, or nil if absent.
    public static func lua(_ name: String, in directory: URL?) -> String? {
        guard let url = directory?.appendingPathComponent("\(name).lua") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The normalised plugin XML read from `directory`, or nil if absent.
    public static func pluginXML(in directory: URL?) -> String? {
        guard let url = directory?.appendingPathComponent("Search_and_Destroy.xml") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// S&D's data modules read from `directory`.
    public static func helperModules(in directory: URL?) -> [String: String] {
        ["constants", "areaReferences", "sqlSetup", "tablesSetup"]
            .reduce(into: [:]) { result, name in result[name] = lua(name, in: directory) }
    }
}
