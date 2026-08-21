import Foundation
@testable import MudCore
import Testing

/// The vendored Lua interpreter is compiled with different C flags per platform
/// (`Package.swift`, `Sources/CLua/PROVENANCE.md`) — iOS drops
/// `LUA_USE_MACOSX` for plain `LUA_USE_POSIX` and adds `LUA_NO_SYSTEM`. These
/// tests pin the language-visible consequences of that split, so a future flag
/// change cannot quietly alter what scripts see.
///
/// Introduced with iOS port phase **I0a** (GitHub #81), the phase that first
/// made MudCore build and test on an iOS simulator.
@Suite("Lua — cross-platform runtime contract")
struct LuaPlatformPortabilityTests {
    /// The stdlib surface a *sandboxed* runtime exposes must be identical on
    /// every platform: the D-10 sandbox is what defines it, not the C flags.
    /// If this diverges, plugins would behave differently on iOS than macOS —
    /// the single thing the port must not do.
    @Test("The sandboxed stdlib surface is platform-independent")
    func sandboxSurfaceIsIdentical() async throws {
        let lua = try LuaRuntime()

        // Present everywhere.
        for expression in [
            "type(os.time) == 'function'",
            "type(os.clock) == 'function'",
            "type(os.date) == 'function'",
            "type(os.difftime) == 'function'",
            "type(string.format) == 'function'",
            "type(math.floor) == 'function'",
            "type(table.insert) == 'function'"
        ] {
            #expect(try await lua.boolean(expression), "\(expression)")
        }

        // Absent everywhere — including os.execute, which is why the C-level
        // iOS patch is unreachable from any real script.
        for expression in [
            "os.execute == nil",
            "os.remove == nil",
            "os.getenv == nil",
            "io == nil",
            "package == nil"
        ] {
            #expect(try await lua.boolean(expression), "\(expression)")
        }
    }

    /// `os.execute` must keep *existing* on both platforms in an unsandboxed
    /// runtime — the iOS patch makes it inert rather than deleting it, so the
    /// shape of the standard library does not change with the platform.
    @Test("Unsandboxed os.execute exists on every platform")
    func unsandboxedExecuteExists() async throws {
        let lua = try LuaRuntime(sandboxed: false)
        #expect(try await lua.boolean("type(os.execute) == 'function'"))
    }

    /// The behavioural half of the split, and the reason `LUA_NO_SYSTEM` exists:
    /// iOS marks `system()` unavailable, so on iOS `os.execute` reports failure
    /// the way a real `system()` would on a host with no shell, while macOS
    /// keeps stock upstream behaviour.
    ///
    /// Deliberately runs a harmless command (`true`, a POSIX no-op that exits 0)
    /// rather than anything with side effects.
    @Test("Unsandboxed os.execute is inert on iOS and functional on macOS")
    func unsandboxedExecuteBehaviour() async throws {
        let lua = try LuaRuntime(sandboxed: false)

        #if os(iOS)
            // LUA_NO_SYSTEM: no shell, nothing is ever spawned.
            #expect(try await lua.number("os.execute()") == 0)
            #expect(try await lua.number(#"os.execute("true")"#) == -1)
        #else
            // Stock Lua 5.1: system(NULL) is non-zero when a shell exists, and
            // a successful command exits 0.
            #expect(try await lua.number("os.execute()") != 0)
            #expect(try await lua.number(#"os.execute("true")"#) == 0)
        #endif
    }
}
