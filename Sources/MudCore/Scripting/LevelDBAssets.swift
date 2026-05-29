import Foundation

/// Accessors for the vendored **leveldb** leveling-database plugin (bundled with
/// MudCore; see `Resources/leveldb/PROVENANCE.md`). Unlike dinv, leveldb is a
/// single self-contained `leveldb.xml` (all Lua inline in its `<script>`; it
/// only `require`s the bundled `gmcphelper`), so there are no sibling modules to
/// register — it runs verbatim through the MUSHclient compatibility shim.
public enum LevelDBAssets {
    private static let subdirectory = "leveldb"

    /// The plugin's well-known MUSHclient id (matches `leveldb.xml`).
    public static let pluginID = "b34c04e52c6c7bced4508230"

    /// The plugin XML (`<plugin>` + aliases + triggers + the inline `<script>`),
    /// parsed by ``MUSHclientPluginLoader``. `nil` if the bundle is missing it.
    public static var pluginXML: String? {
        guard let url = Bundle.module.url(
            forResource: "leveldb", withExtension: "xml", subdirectory: subdirectory
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
