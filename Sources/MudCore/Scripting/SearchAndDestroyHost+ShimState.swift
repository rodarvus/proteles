import Foundation
import os

/// Mirroring S&D's shim-readable state into the shared (shim) runtime.
///
/// A shim plugin's `CallPlugin(<S&D id>, fn, …)` is bridged as a
/// `.callSearchAndDestroy` *effect* — applied by the session only after the
/// calling Lua has returned — so a cross-runtime call can never carry a
/// return value back. A plugin that *reads* S&D (the campaign-driving
/// pattern: "is a target selected?") therefore always saw nil and, live,
/// concluded "no active campaign" while S&D was already mid-hunt
/// (2026-06-10 transcript). The fix: the host snapshots the read accessors
/// after every entry point that ran Lua and, when the combined value
/// changes, emits a `.searchAndDestroyState` effect; the session pushes it
/// into the shim runtime's `__snd_state`, whose values the shim's
/// `CallPlugin` returns synchronously.
extension SearchAndDestroyHost {
    /// Append chunk-scope accessors for S&D state that lives in file-scope
    /// *locals* no other runtime can reach (`main_target_list`, `gotoList`)
    /// — same load-time-injection rationale as the `xg_draw_window` bridge
    /// (`SearchAndDestroyHost+BridgeInjection`). The `type(...)` guards keep
    /// this idempotent and defer to an S&D that ever defines its own.
    /// Appending is safe: both script sources end in plain function
    /// definitions (no top-level `return`), and chunk locals stay in scope
    /// to the end of the chunk.
    static func appendingShimAccessors(to source: String) -> String {
        source + "\n" + shimAccessorsBody
    }

    /// The appended accessor definitions, verbatim. `json` is a core.lua
    /// global (`json = require "json"`).
    static let shimAccessorsBody = """
    -- [Proteles bridge] shim-readable accessors over the chunk's file-scope
    -- locals. `target_as_json` (upstream) covers the CURRENT target; the
    -- target LIST and the go/nx candidate count live in locals, so without
    -- these a reading plugin can't size its nx-cycle or skip dead targets.
    if type(targets_as_json) ~= "function" then
      function targets_as_json()
        if type(main_target_list) ~= "table" then return "[]" end
        local ok, encoded = pcall(json.encode, main_target_list)
        return ok and encoded or "[]"
      end
    end
    if type(goto_list_count) ~= "function" then
      function goto_list_count()
        return type(gotoList) == "table" and #gotoList or 0
      end
    end
    """

    /// One probe of all mirrored accessors, separator-joined (`\31` can't
    /// appear in their JSON/number output) so change detection is a single
    /// string compare. An absent-or-failing accessor contributes "".
    private static let shimStateProbe = """
    (function()
      local sep = string.char(31)
      local function acc(name)
        local f = rawget(_G, name)
        if type(f) ~= "function" then return "" end
        local ok, v = pcall(f)
        if not ok or v == nil then return "" end
        return tostring(v)
      end
      return acc("target_as_json") .. sep .. acc("targets_as_json") .. sep .. acc("goto_list_count")
    end)()
    """

    /// `snd-shim-probe` intervals for Instruments (#59 B2): the probe's real
    /// cost — 3 Lua accessor calls + the canonicalising compare — measured on
    /// a live combat session. Free when nothing is recording.
    private static let signposter = OSSignposter(
        subsystem: "com.proteles", category: "search-and-destroy"
    )

    /// Probe the accessors and, if their combined value changed since the
    /// last push, append a `.searchAndDestroyState` effect to `effects`.
    /// Called by every host entry point that ran Lua (a non-firing line skips
    /// it — nothing can have changed). A failed probe changes nothing.
    func appendingShimState(to effects: [ScriptEffect]) async -> [ScriptEffect] {
        let signpostState = Self.signposter.beginInterval("snd-shim-probe")
        defer { Self.signposter.endInterval("snd-shim-probe", signpostState) }
        guard let snapshot = await evaluate(Self.shimStateProbe) else { return effects }
        let canonical = Self.canonical(snapshot)
        guard canonical != lastShimStateSnapshot else { return effects }
        lastShimStateSnapshot = canonical
        return effects + [Self.shimStateEffect(from: snapshot)]
    }

    /// The current state as an unconditional `.searchAndDestroyState` effect
    /// — the session applies it when (re)attaching the host, so a freshly
    /// (re)built shim runtime starts with the live values rather than waiting
    /// for the next change (plugin/DB ops re-run the whole world load).
    public func shimStateEffect() async -> ScriptEffect {
        let snapshot = await evaluate(Self.shimStateProbe) ?? "\u{1F}\u{1F}"
        lastShimStateSnapshot = Self.canonical(snapshot)
        return Self.shimStateEffect(from: snapshot)
    }

    /// The change-diff form of a probe snapshot. `json.encode`'s key order is
    /// unstable call-to-call (Lua `pairs` order), so comparing raw snapshots
    /// re-emits identical states; the diff therefore compares each part
    /// re-serialized with sorted keys. The RAW accessor output is still what
    /// travels to the shim — readers parse any key order.
    private static func canonical(_ snapshot: String) -> String {
        snapshot.components(separatedBy: "\u{1F}").map { part -> String in
            guard !part.isEmpty,
                  let object = try? JSONSerialization.jsonObject(
                      with: Data(part.utf8), options: [.fragmentsAllowed]
                  ),
                  let data = try? JSONSerialization.data(
                      withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]
                  )
            else { return part }
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\u{1F}")
    }

    /// Decode a probe snapshot ("" fields → nil: accessor absent or failing).
    private static func shimStateEffect(from snapshot: String) -> ScriptEffect {
        var parts = snapshot.components(separatedBy: "\u{1F}")
        while parts.count < 3 {
            parts.append("")
        }
        return .searchAndDestroyState(
            target: parts[0].isEmpty ? nil : parts[0],
            targets: parts[1].isEmpty ? nil : parts[1],
            gotoCount: parts[2].isEmpty ? nil : parts[2]
        )
    }
}

/// Variable persistence (#52): the host runs S&D on its OWN runtime, so the
/// engine-side store wiring never saw its `SetVariable` writes — every
/// session re-scraped the area index and the `xset` flags reset. The session
/// hydrates the host's scope from the per-world ``VariableStore`` BEFORE
/// `load()` (S&D reads `GetVariable` at script top-level: the `xset` flags,
/// `mcvar_area_range`, …) and drains the dirty scopes into the same store
/// after each batch, exactly like the main engine.
public extension SearchAndDestroyHost {
    /// Seed the runtime's S&D-scoped variables from persisted values. Call
    /// before ``load()``.
    func hydrateVariables(_ variables: [String: String]) async {
        await runtime.loadVariables([Self.pluginID: variables])
    }

    /// The scopes mutated since the last call (clears the set).
    func takeDirtyVariableScopes() async -> Set<String> {
        await runtime.takeDirtyVariableScopes()
    }

    /// A snapshot of every scope's variables (for persistence).
    func variablesSnapshot() async -> [String: [String: String]] {
        await runtime.variablesSnapshot()
    }

    /// Set (or create) a variable in an explicit scope (the Variables editor's
    /// host path, #69), marking it dirty so the session persists it.
    func setVariableValue(scope: String, name: String, value: String) async {
        await runtime.setVariableValue(scope: scope, name: name, value: value)
    }

    /// Delete a variable from an explicit scope (#69), marking it dirty.
    func deleteVariableValue(scope: String, name: String) async {
        await runtime.deleteVariableValue(scope: scope, name: name)
    }
}
