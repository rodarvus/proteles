import Foundation

/// Accessors for the vendored **dinv** inventory-manager plugin (bundled with
/// MudCore; see `Resources/dinv/PROVENANCE.md`). dinv runs verbatim through the
/// MUSHclient compatibility shim: its `dinv.xml` bootstrap `dofile`s
/// `dinv_init.lua`, which in turn `dofile`s 20 modules and `require`s the
/// standard helpers (all provided by the shim, including an inert `async`).
///
/// We register dinv's modules with the runtime's module loader keyed by
/// **basename** (no `.lua`), so the plugin's `dofile(dir .. "dinv_X.lua")`
/// resolves from the bundle (the loader falls back to a bundled module matching
/// the file's basename) — no on-disk copy needed.
public enum DinvAssets {
    private static let subdirectory = "dinv"

    /// The plugin's well-known MUSHclient id (matches `dinv.xml`).
    public static let pluginID = "731f94b0f2b54345f836bbaf"

    /// The bootstrap module names dinv `dofile`s (basename keys, no extension).
    /// `dinv_init` is the entry point (loaded by `dinv.xml`'s `<script>`); it
    /// loads the rest. Order is irrelevant for registration — the loader
    /// resolves each on demand.
    public static let moduleNames = [
        "dinv_init", "dinv_db", "dinv_cli", "dinv_items", "dinv_report",
        "dinv_data", "dinv_cache", "dinv_priority", "dinv_score", "dinv_set",
        "dinv_equipment", "dinv_statbonus", "dinv_analyze", "dinv_usage",
        "dinv_unused", "dinv_tags", "dinv_consume", "dinv_portal", "dinv_regen",
        "dinv_migrate", "dinv_dbot"
    ]

    /// A vendored Lua module's source by basename, or `nil` if missing.
    public static func lua(_ name: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "lua", subdirectory: subdirectory
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// All dinv modules keyed by basename, ready for the runtime's module
    /// loader (`registerModules`). Missing files are skipped.
    public static var modules: [String: String] {
        moduleNames.reduce(into: [:]) { result, name in result[name] = lua(name) }
    }

    /// The plugin XML (the `<plugin>` definition + aliases + the `<script>`
    /// bootstrap), parsed by ``MUSHclientPluginLoader``.
    public static var pluginXML: String? {
        guard let url = Bundle.module.url(
            forResource: "dinv", withExtension: "xml", subdirectory: subdirectory
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
