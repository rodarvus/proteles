import Foundation

/// Plugins whose CODE Proteles already bundles (dinv, leveldb, Search &
/// Destroy). They aren't in ``PackagePluginCatalog`` (the standard Aardwolf
/// package), but Proteles ships their functionality — so on import we bring the
/// user's **data** (databases, state) into the bundled feature rather than
/// re-installing the plugin code. Ids are the actual `<plugin id>` of Proteles'
/// bundled copies (Resources/dinv, Resources/leveldb, the S&D submodule).
public enum BundledPluginCatalog {
    public static let ids: Set<String> = [
        "731f94b0f2b54345f836bbaf", // dinv
        "b34c04e52c6c7bced4508230", // leveldb
        "30000000537461726c696e67" // Search & Destroy
    ]

    public static func contains(id: String?) -> Bool {
        guard let id else { return false }
        return ids.contains(id.lowercased())
    }
}
