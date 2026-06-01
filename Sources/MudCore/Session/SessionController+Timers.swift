import Foundation

/// Timer-loop plumbing for ``SessionController``: add/remove/enable timers on the
/// script engine, and the single async loop that fires due timers (the user's
/// script timers + the Search-and-Destroy host's) without busy-waiting. Split out
/// of ``SessionController+Scripting`` to stay within the file-length budget.
public extension SessionController {
    /// Add a timer to the script engine and (re)start the driving loop so the
    /// new deadline is picked up. No-op without a script engine.
    @discardableResult
    func addTimer(_ timer: MudTimer) async throws -> UUID? {
        guard let scriptEngine else { return nil }
        let id = try await scriptEngine.addTimer(timer)
        restartTimerLoop()
        return id
    }

    func removeTimer(id: UUID) async {
        guard let scriptEngine else { return }
        await scriptEngine.removeTimer(id: id)
        restartTimerLoop()
    }

    func setTimerEnabled(_ enabled: Bool, id: UUID) async {
        guard let scriptEngine else { return }
        await scriptEngine.setTimerEnabled(enabled, id: id)
        restartTimerLoop()
    }

    /// Atomically replace a timer and restart the loop once. Used by the
    /// editor's live-apply (avoids the remove-then-add reentrancy that can
    /// duplicate registrations).
    func updateTimer(_ timer: MudTimer) async {
        guard let scriptEngine else { return }
        await scriptEngine.updateTimer(timer)
        restartTimerLoop()
    }

    func setTimerGroupEnabled(_ enabled: Bool, group: String) async {
        guard let scriptEngine else { return }
        await scriptEngine.setTimerGroupEnabled(enabled, group: group)
        restartTimerLoop()
    }

    /// Cancel any running timer loop and start a fresh one. Called whenever
    /// the timer set changes so a newly-added earlier deadline interrupts an
    /// in-flight sleep. The loop exits on its own when no timers remain.
    internal func restartTimerLoop() {
        timerTask?.cancel()
        // Run while either the user's script engine or the S&D host has timers.
        guard scriptEngine != nil || searchAndDestroy != nil else {
            timerTask = nil
            return
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let deadline = await self?.nextTimerDeadline() else { return }
                let delay = deadline.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                if Task.isCancelled { return }
                await self?.applyDueTimers()
            }
        }
    }

    /// The earliest deadline across the user's timers and S&D's timers.
    private func nextTimerDeadline() async -> Date? {
        let engine = await scriptEngine?.nextTimerDeadline()
        let snd = await searchAndDestroy?.nextTimerDeadline()
        return [engine, snd].compactMap(\.self).min()
    }

    /// Fire the timers due at `now` and apply their effects. Factored out so
    /// tests can drive timer firing deterministically without real sleeping.
    internal func applyDueTimers(at now: Date = Date()) async {
        if let scriptEngine {
            await applyScriptEffects(scriptEngine.fireDueTimers(at: now))
            await rearmTimerLoopIfScriptScheduled()
        }
        if let searchAndDestroy {
            await applyScriptEffects(searchAndDestroy.fireTimers(at: now))
            await rearmTimerLoopIfSnDScheduled()
        }
    }
}
