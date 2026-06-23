import Foundation

/// Hold a command stacked after `mapper goto` until the speedwalk actually
/// arrives — the behaviour MUSHclient+Aardwolf get for free.
///
/// In MUSHclient the Aardwolf package speedwalks by sending the whole route to
/// the server as one `run <dirs>` (`speedwalk_prefix = "run"`), so a follow-up
/// command lands in Aardwolf's **server-side** run queue and runs after arrival.
/// Proteles instead walks **client-side**, one segment per `room.info` (so it
/// can pace portals/recalls/custom-exit `wait(N)` the server `run` can't) — but
/// that means nothing orders a follow-up command behind the walk. A macro like
/// `mapper goto 2339` ⏎ `quest complete` fired `quest complete` ~1s early, at
/// the wrong room ("You need to be at a questmaster").
///
/// The fix: when a dispatched command (re)arms a walk (``Mapper/walkArmGeneration``
/// changed), the REST of the same macro/stacked batch is held here and released
/// on `.walkCompleted` — the mapper's arrival-at-final-destination signal. Scope
/// is deliberately the same batch only; a command typed live mid-walk is a fresh
/// dispatch and is NOT held. **Verified for plain speedwalk routes.** Wrong-room
/// arrivals from recall/home/portal/custom-exit segments are left to the stall
/// watchdog rather than failing immediately, because Aardwolf room programs can
/// emit transient rooms during otherwise-valid custom exits.
///
/// Two safety valves, per the agreed policy:
///   - **Supersede → drop.** A new `goto` while commands are held drops the old
///     batch (the user changed their mind) with a note.
///   - **Stall → flush-with-warning.** If the walk makes no progress for
///     ``walkDeferStallTimeout``, the held commands run anyway (never silently
///     swallowed) and the walk is abandoned.
extension SessionController {
    /// No room change for this long while commands are held ⇒ treat the walk as
    /// stalled (blocked exit, wrong room, lag) and flush. Generous so a long but
    /// progressing walk — or a custom-exit `wait(N)` pause — never trips it; each
    /// `room.info` resets the clock.
    static let walkDeferStallTimeout = 15.0

    /// After dispatching one command of a batch, decide whether it armed a walk
    /// and, if so, hold `remaining` until arrival. Returns true when it armed
    /// (the caller must stop dispatching the rest of its batch now).
    ///
    /// `armBefore` is ``Mapper/walkArmGeneration`` sampled *before* the command
    /// ran. A change means this command was a `goto`/`walkto`/`resume`/`next`
    /// that produced a route — as opposed to the mapper merely re-dispatching one
    /// of its own segments while a walk was already running (that doesn't bump
    /// the generation, so it won't false-trigger a hold).
    func holdBatchIfWalkArmed(armBefore: Int, remaining: [String]) async -> Bool {
        guard let mapper else { return false }
        let armAfter = await mapper.walkArmGeneration
        guard armAfter != armBefore else { return false }
        // A (re)armed walk supersedes anything still held from a previous one.
        dropDeferredAfterWalk(reason: "superseded by a new goto")
        deferAfterWalk(remaining)
        return true
    }

    /// Hold `commands` until the in-progress walk arrives. Arms the stall
    /// watchdog the first time the queue becomes non-empty.
    func deferAfterWalk(_ commands: [String]) {
        guard !commands.isEmpty else { return }
        let wasEmpty = deferredAfterWalk.isEmpty
        deferredAfterWalk.append(contentsOf: commands)
        logTranscript(.note, "[walkdefer] holding until arrival: \(commands.joined(separator: " | "))")
        guard wasEmpty else { return }
        walkDeferGeneration += 1
        let generation = walkDeferGeneration
        Task { [weak self] in await self?.runWalkStallWatchdog(generation: generation) }
    }

    /// Drop the held batch without running it (a new goto replaced it). No-op
    /// when nothing is held.
    func dropDeferredAfterWalk(reason: String) {
        guard !deferredAfterWalk.isEmpty else { return }
        logTranscript(.note, "[walkdefer] dropped (\(reason)): \(deferredAfterWalk.joined(separator: " | "))")
        deferredAfterWalk.removeAll()
        walkDeferGeneration += 1 // supersede any running watchdog
    }

    /// Release the held batch — called on `.walkCompleted` (arrival at the goto
    /// target). Re-runs each command through the normal input path; if one is
    /// itself a `goto`, ``sendWalkAwareBatch`` re-holds the remainder for that
    /// new walk.
    func drainDeferredAfterWalk() async {
        guard !deferredAfterWalk.isEmpty else { return }
        walkDeferGeneration += 1 // we're handling it; retire the watchdog
        let pending = deferredAfterWalk
        deferredAfterWalk.removeAll()
        logTranscript(.note, "[walkdefer] arrived — running \(pending.count) held command(s)")
        await sendWalkAwareBatch(pending)
    }

    /// Send a batch of commands in order, holding the remainder the instant one
    /// of them (re)arms a walk. Used by macro `.command` firing and by the
    /// deferred-queue drain/flush. Drained commands re-echo as they run (so the
    /// user sees `quest complete` fire on arrival); a `goto` typed inline with a
    /// trailing stacked command is the one case that can double-echo the tail,
    /// which is rare and cosmetic.
    func sendWalkAwareBatch(_ commands: [String]) async {
        for (index, command) in commands.enumerated() {
            let armBefore = await mapper?.walkArmGeneration ?? 0
            try? await send(command)
            if await holdBatchIfWalkArmed(armBefore: armBefore, remaining: Array(commands[(index + 1)...])) {
                return
            }
        }
    }

    /// Watchdog: flush the held batch if the walk makes no progress for
    /// ``walkDeferStallTimeout``. Each `room.info` moves the player, so a healthy
    /// walk keeps resetting `lastRoom`; only a genuine stall (blocked, wrong
    /// room, dropped link) reaches the flush.
    private func runWalkStallWatchdog(generation: Int) async {
        var lastRoom = await mapper?.currentRoomUID
        while true {
            try? await Task.sleep(nanoseconds: Self.nanoseconds(Self.walkDeferStallTimeout))
            guard generation == walkDeferGeneration, !deferredAfterWalk.isEmpty else { return }
            let room = await mapper?.currentRoomUID
            if room != lastRoom {
                lastRoom = room // progressed — keep waiting
                continue
            }
            await flushStalledDeferred(generation: generation)
            return
        }
    }

    /// Run the held commands anyway after a stall, with a visible warning, and
    /// abandon the stuck walk. Re-checks the generation so a walk that completed
    /// (or was superseded) in the meantime is left alone.
    private func flushStalledDeferred(generation: Int) async {
        guard generation == walkDeferGeneration, !deferredAfterWalk.isEmpty else { return }
        let pending = deferredAfterWalk
        deferredAfterWalk.removeAll()
        walkDeferGeneration += 1
        logTranscript(.note, "[walkdefer] walk stalled — flushing \(pending.count) held command(s)")
        await applyScriptEffects([
            .note(
                text: "Walk did not complete; running deferred command(s) anyway.",
                foreground: "yellow",
                background: nil
            ),
            .sendNoEcho(Mapper.endRunningMarker) // reset the 999 "running" broadcast
        ])
        await mapper?.cancelWalk()
        await sendWalkAwareBatch(pending)
    }

    /// Drop any held batch on teardown/disconnect — the walk can't complete, and
    /// re-running stale commands into a fresh session would be wrong.
    func clearWalkDeferral() {
        deferredAfterWalk.removeAll()
        walkDeferGeneration += 1
    }
}
