import Foundation
@testable import MudCore
import Testing

/// `AddTimer` named one-shots must be cancellable by `DeleteTimer` (and
/// supersedable by re-arming with the same name). Regression for the shim bug
/// where `AddTimer` was a fire-and-forget one-shot and `DeleteTimer` a no-op:
/// a plugin's "arm a safety timeout, then delete it on success" pattern leaked,
/// so the stale timer still fired (e.g. Hadar_Spellups' 10s slist safety reset
/// re-opened its capture gate every tick → endless "Getting/Got skills").
@Suite("LuaRuntime — AddTimer/DeleteTimer cancellation")
struct PluginTimerCancelTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    /// The deferred Lua body the timer's one-shot will run (from the scheduleAfter
    /// effect AddTimer emits).
    private func deferredBody(_ effects: [ScriptEffect]) throws -> String {
        let body = effects.compactMap { effect -> String? in
            if case .scheduleAfter(_, _, let body) = effect { return body }
            return nil
        }.first
        return try #require(body, "AddTimer should emit a scheduleAfter one-shot")
    }

    @Test("a live AddTimer one-shot runs its script when it fires")
    func liveTimerFires() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("fired = false; function mark(n) fired = true end")
        let body = try await deferredBody(lua.run("AddTimer('t', 0, 0, 10, '', 0, 'mark')"))
        _ = try await lua.run(body) // simulate the one-shot firing
        #expect(try await lua.boolean("fired") == true)
    }

    @Test("DeleteTimer cancels a pending one-shot (it self-skips on fire)")
    func deleteCancels() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("fired = false; function mark(n) fired = true end")
        let body = try await deferredBody(lua.run("AddTimer('t', 0, 0, 10, '', 0, 'mark')"))
        _ = try await lua.run("DeleteTimer('t')")
        _ = try await lua.run(body) // the one-shot fires, but must do nothing now
        #expect(try await lua.boolean("fired") == false)
    }

    @Test("re-arming with the same name supersedes the older one-shot")
    func replaceSupersedes() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("count = 0; function mark(n) count = count + 1 end")
        let first = try await deferredBody(lua.run("AddTimer('t', 0, 0, 10, '', 0, 'mark')"))
        let second = try await deferredBody(lua.run("AddTimer('t', 0, 0, 10, '', 0, 'mark')"))
        _ = try await lua.run(first) // stale generation → must self-skip
        _ = try await lua.run(second) // current generation → fires once
        #expect(try await lua.number("count") == 1)
    }

    @Test("EnablePlugin / DisablePlugin / IsPluginInstalled are benign (return eOK / self)")
    func pluginControlStubs() async throws {
        let lua = try await shimmed()
        // A self-disable on install (then return) must not error.
        let effects = try await lua.run(
            "check(EnablePlugin(GetPluginID(), false)); check(DisablePlugin(GetPluginID()))"
        )
        #expect(effects.isEmpty) // no outward effects, no Lua error
        #expect(try await lua.boolean("IsPluginInstalled(GetPluginID())") == true)
        #expect(try await lua.boolean("IsPluginInstalled('someone_else')") == false)
    }
}
