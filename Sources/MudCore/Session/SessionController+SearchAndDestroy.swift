import Foundation

/// The session's Search-and-Destroy plumbing: feeding it lines/commands/GMCP,
/// (re)attaching the host, and mirroring its shim-readable state. Split out of
/// ``SessionController+Scripting`` to keep that file within the length budget.
public extension SessionController {
    /// Run a received line through Search-and-Destroy's triggers and apply the
    /// effects it produced (sends, echoes, a re-published model). Returns
    /// whether S&D gagged the line (`omit_from_output`). No-op (false) when no
    /// S&D host is attached.
    @discardableResult
    internal func applySearchAndDestroyLine(_ line: Line) async -> Bool {
        guard let searchAndDestroy else { return false }
        // `runs` = MUSHclient's 4th `styles` arg (S&D scan/consider re-render from it).
        let result = await searchAndDestroy.process(line.text, runs: line.runs)
        await applyScriptEffects(result.effects)
        await rearmTimerLoopIfSnDScheduled()
        return result.gag
    }

    /// If S&D scheduled a `DoAfter`/`DoAfterSpecial` one-shot, restart the timer
    /// loop so it fires (the loop exits when no timers remain — an idle deferral).
    internal func rearmTimerLoopIfSnDScheduled() async {
        if await searchAndDestroy?.takeDidScheduleTimer() == true {
            restartTimerLoop()
        }
    }

    /// Offer a typed command to Search-and-Destroy's aliases first. Returns
    /// `true` if S&D handled it (effects applied), so the caller skips the
    /// normal alias/verbatim path. No-op (false) without an S&D host.
    func handleSearchAndDestroyCommand(_ command: String) async -> Bool {
        guard let searchAndDestroy,
              let effects = await searchAndDestroy.expandCommand(command)
        else { return false }
        await applyScriptEffects(effects)
        await rearmTimerLoopIfSnDScheduled()
        await persistVariablesIfDirty()
        return true
    }

    /// Attach the live Search-and-Destroy host (already configured + loaded),
    /// replay the current GMCP snapshot so it's initialised (not stuck in an
    /// "unknown state" until the next `char.status`), and start its timer loop.
    /// Call when a world loads or when the host is re-created mid-session (a DB
    /// import or plugin change re-runs the world load).
    func attachSearchAndDestroy(_ host: SearchAndDestroyHost) async {
        searchAndDestroy = host
        // Shim plugins can now gate on + call into S&D (IsPluginInstalled /
        // CallPlugin bridges).
        await scriptEngine?.setBridgedPlugin(SearchAndDestroyHost.pluginID, installed: true)
        // Seed the shim's synchronous S&D reads (`__snd_state`) with the live
        // values — a world reload rebuilds the shim runtime, and waiting for
        // the next state *change* would leave reads answering nil until then.
        await applyScriptEffects([host.shimStateEffect()])
        // The connect-time state handler only fires on a transition, so a host
        // attached mid-session must be told it's connected + given the current
        // GMCP snapshot, or its first xcp sits in an "unknown state".
        if state == .connected {
            await host.setConnected(true)
            await replayGMCPSnapshot(to: host)
        }
        restartTimerLoop()
    }

    /// Replay the latest per-package GMCP snapshot into `host` so it's
    /// initialised immediately. Order: char.base/status first (tier/state),
    /// then room.info (sets current_room), then the rest — so a freshly
    /// re-attached host has a ready character + a known room right away.
    func replayGMCPSnapshot(to host: SearchAndDestroyHost) async {
        let priority = ["char.base", "char.status", "room.info"]
        let ordered = priority.filter { latestGMCPByPackage[$0] != nil }
            + latestGMCPByPackage.keys.filter { !priority.contains($0) }.sorted()
        for package in ordered {
            guard let json = latestGMCPByPackage[package] else { continue }
            await applyScriptEffects(host.applyGMCP(package: package, json: json))
        }
    }

    /// Force a Search-and-Destroy campaign/quest detection pass (its
    /// `do_cp_info`). Used by the panel's "Scan now" and the post-connect
    /// auto-scan. No-op without an S&D host.
    func scanSearchAndDestroy() async {
        guard let searchAndDestroy else { return }
        await applyScriptEffects(searchAndDestroy.scanForActivity())
        await rearmTimerLoopIfSnDScheduled()
        await persistVariablesIfDirty()
    }
}
