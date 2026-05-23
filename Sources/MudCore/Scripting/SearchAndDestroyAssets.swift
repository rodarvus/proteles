import Foundation

/// Accessors for the vendored Search-and-Destroy assets (bundled with
/// MudCore, see `Resources/SearchAndDestroy/PROVENANCE.md`). The native S&D
/// plugin loads its logic from these — its `core.lua` (the original plugin
/// `<script>`), data modules, and `require`d helpers — verbatim.
public enum SearchAndDestroyAssets {
    private static let subdirectory = "SearchAndDestroy"

    /// The plugin's main script (the original `<script>` CDATA), or nil if
    /// the resource is missing.
    public static var core: String? {
        lua("core")
    }

    /// A vendored Lua module's source by name (e.g. `areaReferences`,
    /// `constants`, `wait`, `sqlSetup`, `tablesSetup`).
    public static func lua(_ name: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "lua", subdirectory: subdirectory
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The normalised plugin XML (source for the trigger/alias/timer
    /// definitions; parsed by a tolerant extractor since MUSHclient's XML
    /// isn't strict enough for `XMLParser`).
    public static var pluginXML: String? {
        guard let url = Bundle.module.url(
            forResource: "Search_and_Destroy", withExtension: "xml", subdirectory: subdirectory
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The vendored helper modules to register with the runtime's module
    /// loader (so S&D's `require`s resolve), keyed by module name.
    public static var helperModules: [String: String] {
        ["constants", "areaReferences", "sqlSetup", "tablesSetup", "wait", "check"]
            .reduce(into: [:]) { result, name in result[name] = lua(name) }
    }
}
