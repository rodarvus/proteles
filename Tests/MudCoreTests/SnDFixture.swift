import Foundation
@testable import MudCore

/// Points ``SearchAndDestroyAssets`` at the bundled S&D test fixture. The
/// plugin's Lua (Crowley's) is shipped only to the *test* bundle as a
/// provenanced fixture (`Fixtures/SearchAndDestroy`), not the app — so S&D
/// tests must install it before loading. Call from each S&D suite's `init`.
enum SnDFixture {
    /// The bundled fixture directory holding the S&D Lua, or nil if the
    /// resource is absent. Prefer this with the `in:`-injectable accessors so a
    /// suite reads the fixture without mutating (and racing on) the shared
    /// ``SearchAndDestroyAssets/installDirectory`` global.
    static var directory: URL? {
        Bundle.module.url(
            forResource: "core", withExtension: "lua", subdirectory: "Fixtures/SearchAndDestroy"
        )?.deletingLastPathComponent()
    }

    /// True once the fixture is reachable + wired (false if the resource is
    /// somehow absent, so suites can skip rather than hard-fail). Sets the
    /// shared global — only suites that exercise the global accessors (e.g. the
    /// host) need this; prefer ``directory`` + the `in:` accessors otherwise.
    @discardableResult
    static func install() -> Bool {
        guard let dir = directory else { return false }
        SearchAndDestroyAssets.installDirectory = dir
        return true
    }
}
