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
        guard let expect = walkExpect, currentRoomUID == expect else { return [] }
        walkIndex += 1
        guard walkIndex < walkSegments.count else {
            // The final segment already carried the `{end running}` marker
            // (emitted with it, or by its wait-pacer); nothing more to send.
            walkExpect = nil
            return []
        }
        let segment = walkSegments[walkIndex]
        let isFinal = walkIndex == walkSegments.count - 1
        // Wait for this segment only if more follow; the last one needs no wait.
        walkExpect = isFinal ? nil : segment.expectUID
        return segmentEffects(segment, isFinal: isFinal)
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
    }
}
