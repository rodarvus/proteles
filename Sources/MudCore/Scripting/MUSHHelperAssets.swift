import Foundation

/// Nick Gammon's standard MUSHclient helper libraries (`wait`, `check`),
/// bundled with MudCore (see `Resources/MUSHHelpers/PROVENANCE.md`). They carry
/// no copyleft and are needed by the compat shim and by plugins that
/// `require "wait"` / `require "check"` (dinv, Search-and-Destroy).
public enum MUSHHelperAssets {
    private static let subdirectory = "MUSHHelpers"

    /// A bundled helper module's source by name (`wait`, `check`).
    public static func lua(_ name: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "lua", subdirectory: subdirectory
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// `wait` + `check`, keyed by module name, for registering with a runtime.
    public static var modules: [String: String] {
        ["wait", "check"].reduce(into: [:]) { result, name in result[name] = lua(name) }
    }
}
