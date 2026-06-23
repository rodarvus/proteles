import Foundation

/// The segmented-walk stepper: a route is sent one segment at a time, each
/// released only once the previous segment's destination `room.info` arrives
/// (so a portal hop waits for its whoosh before the follow-on `run`). Every
/// walk is wrapped in the reference's `{begin running}`/`{end running}` markers,
/// and a custom-exit segment that embeds `wait(N)` is paced session-side
/// (``WaitWalk`` / `.walkWithWaits`) — the faithful `ExecuteWithWaits` protocol.
/// Split out of ``Mapper`` for the file-length budget; the walk state itself
/// (`walkSegments`/`walkIndex`/`walkExpect`) lives on the actor.
extension Mapper {
    /// The marker commands the reference's `ExecuteWithWaits` sends around every
    /// speedwalk so the mapper's own triggers broadcast the cross-plugin
    /// "running" state (`BroadcastPlugin(999, …)`). `echo` reflects the text
    /// back from the server; the session gags the reflected line and fires the
    /// 999 broadcast on it (the reference's begin/end-running triggers).
    static let beginRunningMarker = "echo {begin running}"
    static let endRunningMarker = "echo {end running}"

    /// On a `room.info`, advance a pending segmented walk. If we've arrived in
    /// the room the last-sent segment was heading to, send the next segment;
    /// otherwise (still en route, or no walk) do nothing. Returns the effect(s)
    /// to apply now.
    public func advanceWalk() -> [ScriptEffect] {
        var effects: [ScriptEffect] = []
        // Release the next segment once we've arrived where the last-sent one
        // was heading (still en route, or no walk → nothing to release).
        if let expect = walkExpect, let current = currentRoomUID {
            if current == expect {
                walkIndex += 1
                if walkIndex < walkSegments.count {
                    let segment = walkSegments[walkIndex]
                    let isFinal = walkIndex == walkSegments.count - 1
                    // Wait for this segment only if more follow; the last needs none.
                    walkSegmentOriginUID = current
                    walkExpect = isFinal ? nil : segment.expectUID
                    effects.append(contentsOf: segmentEffects(segment, isFinal: isFinal))
                } else {
                    // The final segment already carried the `{end running}` marker
                    // (emitted with it, or by its wait-pacer); nothing more to send.
                    walkExpect = nil
                }
            }
        }
        // Independently of segment bookkeeping, signal completion the moment we
        // actually LAND in the final destination — for any route that reaches its
        // target (plain run, single step, portal first jump). ``walkExpect`` can't
        // serve as this gate: it clears when the final segment is *sent* (before
        // arrival) and is nil for a one-step walk. The session releases commands
        // deferred behind `mapper goto` on this. (A recall-routed goto whose
        // recall lands somewhere other than the expected uid never reaches this —
        // issue #78.)
        if let target = walkFinalTarget, currentRoomUID == target {
            walkFinalTarget = nil
            effects.append(.walkCompleted(uid: target))
        }
        return effects
    }

    /// Whether a segmented walk is in progress — armed by ``route`` and cleared
    /// when the destination `room.info` lands (or by ``clearWalk``). The session
    /// reads this to decide whether to keep holding deferred commands.
    public var isWalking: Bool {
        walkFinalTarget != nil
    }

    /// Abandon any in-progress walk outright (the session's stall watchdog gave
    /// up on it). Unlike ``advanceWalk``'s natural completion, this emits no
    /// `.walkCompleted` — the session is already flushing the deferred queue.
    public func cancelWalk() {
        clearWalk()
    }

    /// Effects to emit one walk ``Speedwalk/Segment``. A command with embedded
    /// `wait(N)` pauses becomes a `.walkWithWaits` so the session paces it
    /// (ExecuteWithWaits); a plain command is a straight `.execute`. The final
    /// segment carries the `{end running}` marker — emitted here for a plain
    /// command, or by the pacer (`emitEndRunning`) for a wait-bearing one, so it
    /// always lands *after* the segment's last command.
    func segmentEffects(_ segment: Speedwalk.Segment, isFinal: Bool) -> [ScriptEffect] {
        if WaitWalk.containsWait(segment.command) {
            return [.walkWithWaits(command: segment.command, emitEndRunning: isFinal)]
        }
        var effects: [ScriptEffect] = [.execute(segment.command)]
        if isFinal { effects.append(.sendNoEcho(Self.endRunningMarker)) }
        return effects
    }

    /// Cancel any in-progress segmented walk (a new route supersedes the old).
    func clearWalk() {
        walkSegments = []
        walkIndex = 0
        walkExpect = nil
        walkSegmentOriginUID = nil
        walkFinalTarget = nil
    }
}
