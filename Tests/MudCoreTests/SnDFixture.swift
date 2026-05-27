import Foundation
@testable import MudCore

/// Points ``SearchAndDestroyAssets`` at the bundled S&D test fixture. The
/// plugin's Lua (Crowley's) is shipped only to the *test* bundle as a
/// provenanced fixture (`Fixtures/SearchAndDestroy`), not the app — so S&D
/// tests must install it before loading. Call from each S&D suite's `init`.
enum SnDFixture {
    /// True once the fixture is reachable + wired (false if the resource is
    /// somehow absent, so suites can skip rather than hard-fail).
    @discardableResult
    static func install() -> Bool {
        guard let core = Bundle.module.url(
            forResource: "core", withExtension: "lua", subdirectory: "Fixtures/SearchAndDestroy"
        ) else { return false }
        SearchAndDestroyAssets.installDirectory = core.deletingLastPathComponent()
        return true
    }
}
