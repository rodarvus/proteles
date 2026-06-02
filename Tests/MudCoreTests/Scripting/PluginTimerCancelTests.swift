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

    /// All deferred bodies an effect set carries (a recurring fire re-arms
    /// itself, emitting a fresh `scheduleAfter` each time it runs).
    private func deferredBodies(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { effect in
            if case .scheduleAfter(_, _, let body) = effect { return body }
            return nil
        }
    }

    /// Regression for #18: a recurring (non-OneShot) AddTimer used to fire once
    /// and never again — a plugin arming a periodic refresh (who/stat/clock)
    /// ticked a single time. MUSHclient re-fires every interval; we now match by
    /// having the fire body re-arm itself, guarded by the same liveness/generation
    /// so DeleteTimer/Replace still stop it.
    @Test("a recurring (non-OneShot) AddTimer re-fires every interval")
    func recurringRefires() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("count = 0; function tick(n) count = count + 1 end")
        // flags = 0 → not OneShot → recurring (MUSHclient's default).
        let body = try await deferredBody(lua.run("AddTimer('r', 0, 0, 5, '', 0, 'tick')"))
        // First fire: runs the script AND schedules the next interval.
        let firstFire = try await lua.run(body)
        #expect(try await lua.number("count") == 1)
        let next = try #require(deferredBodies(firstFire).first, "a recurring fire must re-arm itself")
        // Second fire from the re-armed body: fires again and re-arms again.
        let secondFire = try await lua.run(next)
        #expect(try await lua.number("count") == 2)
        #expect(!deferredBodies(secondFire).isEmpty) // still recurring
    }

    @Test("a OneShot AddTimer fires once and does not re-arm")
    func oneShotDoesNotRefire() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("count = 0; function tick(n) count = count + 1 end")
        // timer_flag.OneShot == 4: fire exactly once, no re-arm scheduled.
        let body = try await deferredBody(lua.run("AddTimer('o', 0, 0, 5, '', timer_flag.OneShot, 'tick')"))
        let fire = try await lua.run(body)
        #expect(try await lua.number("count") == 1)
        #expect(deferredBodies(fire).isEmpty)
    }

    @Test("DeleteTimer stops a recurring timer mid-chain")
    func deleteStopsRecurrence() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("count = 0; function tick(n) count = count + 1 end")
        let body = try await deferredBody(lua.run("AddTimer('r', 0, 0, 5, '', 0, 'tick')"))
        let firstFire = try await lua.run(body)
        #expect(try await lua.number("count") == 1)
        let next = try #require(deferredBodies(firstFire).first)
        _ = try await lua.run("DeleteTimer('r')")
        let secondFire = try await lua.run(next) // guard fails → no fire, no re-arm
        #expect(try await lua.number("count") == 1)
        #expect(deferredBodies(secondFire).isEmpty)
    }

    // #29: SetTimerOption("enabled") on a shim timer (a doAfter chain, not a
    // TimerEngine entry) pauses by clearing liveness and resumes by bumping the
    // generation + re-arming from the spec.
    @Test("SetTimerOption enabled pauses, then re-arms, a recurring shim timer")
    func setTimerOptionEnabled() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("function tick(n) end")
        let armed = try await lua.run("AddTimer('m', 0, 0, 5, '', 0, 'tick')")
        #expect(!deferredBodies(armed).isEmpty) // first fire scheduled
        // Disable → pause: nothing newly scheduled.
        let off = try await lua.run("SetTimerOption('m','enabled',false)")
        #expect(deferredBodies(off).isEmpty)
        // Re-enable → re-armed: a fresh fire is scheduled.
        let on = try await lua.run("SetTimerOption('m','enabled',1)")
        #expect(!deferredBodies(on).isEmpty)
    }

    @Test("DeleteTemporaryTimers clears only Temporary-flagged timers")
    func deleteTemporaryTimers() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("function tick(n) end")
        // m1 Temporary; m2 permanent.
        _ = try await lua.run("AddTimer('m1', 0, 0, 5, '', timer_flag.Temporary, 'tick')")
        _ = try await lua.run("AddTimer('m2', 0, 0, 5, '', 0, 'tick')")
        #expect(try await lua.number("DeleteTemporaryTimers()") == 1)
        #expect(try await lua.number("IsTimer('m1')") == 30017) // gone
        #expect(try await lua.number("IsTimer('m2')") == 0) // kept
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
