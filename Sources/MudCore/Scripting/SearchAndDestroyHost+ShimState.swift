import Foundation

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
    /// The accessors the shim mirrors. `target_as_json` is upstream S&D API
    /// (intended for exactly this kind of cross-plugin read); the other two
    /// are appended into the chunk by ``appendingShimAccessors(to:)``.
    static let shimAccessorNames = ["target_as_json", "targets_as_json", "goto_list_count"]

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

    /// Probe the accessors and, if their combined value changed since the
    /// last push, append a `.searchAndDestroyState` effect to `effects`.
    /// Called by every host entry point that ran Lua (a non-firing line skips
    /// it — nothing can have changed). A failed probe changes nothing.
    func appendingShimState(to effects: [ScriptEffect]) async -> [ScriptEffect] {
        guard let snapshot = await evaluate(Self.shimStateProbe),
              snapshot != lastShimStateSnapshot
        else { return effects }
        lastShimStateSnapshot = snapshot
        return effects + [Self.shimStateEffect(from: snapshot)]
    }

    /// The current state as an unconditional `.searchAndDestroyState` effect
    /// — the session applies it when (re)attaching the host, so a freshly
    /// (re)built shim runtime starts with the live values rather than waiting
    /// for the next change (plugin/DB ops re-run the whole world load).
    public func shimStateEffect() async -> ScriptEffect {
        let snapshot = await evaluate(Self.shimStateProbe) ?? "\u{1F}\u{1F}"
        lastShimStateSnapshot = snapshot
        return Self.shimStateEffect(from: snapshot)
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
