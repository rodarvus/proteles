import Foundation

/// Nick Gammon's standard MUSHclient helper libraries (`wait`, `check`,
/// `string_split`), bundled with MudCore (see `Resources/MUSHHelpers/PROVENANCE.md`).
/// They carry no copyleft and are needed by the compat shim and by plugins that
/// `require "wait"` / `require "check"` / `require "string_split"` (dinv,
/// Search-and-Destroy, Hadar, …).
public enum MUSHHelperAssets {
    private static let subdirectory = "MUSHHelpers"

    /// A bundled helper module's source by name (`wait`, `check`, `string_split`).
    public static func lua(_ name: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "lua", subdirectory: subdirectory
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// `wait` + `check` + `string_split`, keyed by module name, for registering.
    public static var modules: [String: String] {
        ["wait", "check", "string_split"].reduce(into: [:]) { result, name in result[name] = lua(name) }
    }
}
