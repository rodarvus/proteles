import Foundation

/// The mapper's faithful `ExecuteWithWaits` movement protocol (D-NN), run
/// session-side because it owns both the wire and the inbound line stream the
/// synchronisation rides on.
///
/// The Aardwolf mapper wraps **every** speedwalk in this protocol
/// (`aardmapper.lua` `start_speedwalk` → `ExecuteWithWaits`):
///
///   1. `echo {begin running}` — the server reflects it; the mapper's trigger
///      fires `BroadcastPlugin(999, "kinda_busy")` so other plugins back off
///      while you walk.
///   2. For each `wait(N)` in the command: execute the commands before it, send
///      `echo {mapper_wait}wait(N)`, **block until that echo reflects back**
///      (so the server has processed everything sent so far), then pause N
///      seconds. `wait(N)` is never sent as a command.
///   3. `echo {end running}` → `BroadcastPlugin(999, "ok_you_can_go_now")`.
///
/// The mapper emits `.sendNoEcho(beginRunningMarker)` and, for wait-bearing
/// segments, `.walkWithWaits`; the markers reflect through ``handleWalkMarker``.
extension SessionController {
    /// Broadcast id the reference mapper uses for the running state, and the two
    /// text payloads other plugins match in `OnPluginBroadcast`.
    static let runningBroadcastID = 999
    static let kindaBusyText = "kinda_busy"
    static let okToGoText = "ok_you_can_go_now"

    /// Distinctive marker substrings (braced, so a normal MUD line can't collide)
    /// matched on the reflected `echo` lines. Matched by `contains` so any
    /// `echo_prefix` the server adds is tolerated.
    static let beginRunningTag = "{begin running}"
    static let endRunningTag = "{end running}"
    static let mapperWaitTag = "{mapper_wait}wait("

    /// Intercept a reflected mapper-walk marker line: gag it from the output and
    /// run its side effect (fire the 999 broadcast / release the paused walk).
    /// Returns true if `line` was a marker (and thus consumed). The reference
    /// gags these with `omit_from_output` and acts in the trigger.
    func handleWalkMarker(_ line: Line) async -> Bool {
        let text = line.text
        if text.contains(Self.mapperWaitTag) {
            logTranscript(.gag, "[walkmarker] \(text)")
            resumeWaitMarker()
            return true
        }
        if text.contains(Self.beginRunningTag) {
            logTranscript(.gag, "[walkmarker] \(text)")
            await fireRunningBroadcast(Self.kindaBusyText)
            return true
        }
        if text.contains(Self.endRunningTag) {
            logTranscript(.gag, "[walkmarker] \(text)")
            await fireRunningBroadcast(Self.okToGoText)
            return true
        }
        return false
    }

    /// Deliver `BroadcastPlugin(999, <text>)` to every plugin's
    /// `OnPluginBroadcast`, as the reference's begin/end-running triggers do.
    private func fireRunningBroadcast(_ text: String) async {
        guard let scriptEngine else { return }
        await applyScriptEffects(scriptEngine.deliverMapperBroadcast(
            id: Self.runningBroadcastID,
            text: text
        ))
    }

    /// Handle `.walkWithWaits` from the control-effect fallthrough: pace the
    /// walk on a detached task so its `wait(N)` pauses don't block inbound
    /// processing (the reflected `{mapper_wait}` echo it waits on arrives
    /// through that same inbound path). A no-op for any other effect.
    func applyWalkEffect(_ effect: ScriptEffect) async {
        switch effect {
        case .walkWithWaits(let command, let emitEndRunning):
            Task { await self.runWaitWalk(command, emitEndRunning: emitEndRunning) }
        case .walkCompleted:
            // Arrived at a `mapper goto` target — release the commands held
            // behind the walk (a macro/stacked command after the goto). Drained
            // inline so they reach the wire within this `room.info`'s handling,
            // when we're confirmed to be in the destination room.
            await drainDeferredAfterWalk()
        default:
            break
        }
    }

    /// Pace a `.walkWithWaits` command (the mapper's wait-bearing segment): run
    /// the command chunks, and turn each `wait(N)` into an echo-synchronised
    /// pause exactly like `ExecuteWithWaits`. A new walk (or teardown) bumps
    /// ``walkGeneration`` so this loop, if superseded, stops emitting.
    func runWaitWalk(_ command: String, emitEndRunning: Bool) async {
        walkGeneration += 1
        resumeWaitMarker() // release any pacer the prior walk left parked
        let generation = walkGeneration
        for step in WaitWalk.steps(from: command) {
            guard generation == walkGeneration else { return }
            switch step {
            case .commands(let chunk):
                // `Execute`-equivalent: aliases/plugins handle it and a stacked
                // chunk (`open south;s`) splits — never sent raw.
                await applyScriptEffects([.execute(chunk)])
            case .wait(let seconds):
                await applyScriptEffects([.sendNoEcho(Self.mapperWaitCommand(seconds))])
                await parkForWaitMarker(timeout: seconds + Self.walkMarkerTimeoutMargin)
                guard generation == walkGeneration else { return }
                try? await Task.sleep(nanoseconds: Self.nanoseconds(seconds))
            }
        }
        guard generation == walkGeneration else { return }
        if emitEndRunning {
            await applyScriptEffects([.sendNoEcho(Mapper.endRunningMarker)])
        }
    }

    /// The `echo {mapper_wait}wait(N)` round-trip marker for a pause (`%g` drops
    /// a trailing `.0` so an integer wait reads `wait(1)`, like the reference).
    static func mapperWaitCommand(_ seconds: Double) -> String {
        "echo {mapper_wait}wait(\(String(format: "%g", seconds)))"
    }

    /// Seconds → nanoseconds, clamped non-negative.
    static func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    /// Extra seconds to wait for a `{mapper_wait}` echo before giving up, so a
    /// dropped/lagged reflection can't wedge the pacer (the faithful path
    /// resolves the instant the line reflects).
    static let walkMarkerTimeoutMargin = 5.0

    /// Park the pacer until the reflected `{mapper_wait}` echo arrives, with a
    /// defensive timeout. Resolved exactly once (whichever of arrival / timeout
    /// / teardown fires first); the rest no-op because the continuation is
    /// cleared on resume.
    private func parkForWaitMarker(timeout: Double) async {
        let generation = walkGeneration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waitMarkerContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
                await self?.timeoutWaitMarker(generation: generation)
            }
        }
    }

    /// Resume the parked pacer (marker arrived, or teardown). Idempotent.
    func resumeWaitMarker() {
        waitMarkerContinuation?.resume()
        waitMarkerContinuation = nil
    }

    /// Resume on timeout only if this is still the walk that parked.
    private func timeoutWaitMarker(generation: Int) {
        guard generation == walkGeneration else { return }
        resumeWaitMarker()
    }

    /// Stop any in-flight wait-walk pacer (called from teardown): a new
    /// generation makes the loop exit, and the parked continuation is released.
    func cancelWaitWalk() {
        walkGeneration += 1
        resumeWaitMarker()
    }
}
