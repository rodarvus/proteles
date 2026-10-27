import Foundation
@testable import MudCore
import Testing

/// Playback discipline (S1 step 3, `docs/plans/S1_ITEM3_PROPOSAL.md`): a run
/// of repeats plays once (0.25 s of quiet per event before it plays again)
/// and a 5-cue cap that replaces the oldest.
@Suite("CueGovernor — playback discipline")
struct CueGovernorTests {
    private func cue(_ event: String?, file: String = "x.wav") -> SoundCue {
        SoundCue(file: file, volume: 1, pan: 0, event: event)
    }

    /// Admit and, when allowed, start under the next ID — the player's loop.
    private func play(
        _ governor: inout CueGovernor, _ cue: SoundCue, at time: TimeInterval, id: Int
    ) -> CueGovernor.Decision {
        let decision = governor.admit(cue, at: time)
        if decision != .drop { governor.started(id) }
        return decision
    }

    @Test("the same event inside the gap is dropped; after a quiet gap, it plays again")
    func sameEventGap() {
        var governor = CueGovernor()
        #expect(play(&governor, cue("bonus_item"), at: 0.0, id: 1) == .play)
        #expect(play(&governor, cue("bonus_item"), at: 0.2, id: 2) == .drop)
        #expect(play(&governor, cue("bonus_item"), at: 0.5, id: 3) == .play)
    }

    @Test("a gap of exactly 0.25 s plays")
    func exactGapPlays() {
        var governor = CueGovernor()
        #expect(governor.admit(cue("tell"), at: 10.0) == .play)
        #expect(governor.admit(cue("tell"), at: 10.25) == .play)
    }

    /// The live case: a spellup recast is `{affon}` every ~113 ms for eight
    /// seconds (`session-20261027-122534`). It is one thing happening.
    @Test("a run of repeats plays once, however long it lasts; a pause starts a new run")
    func runPlaysOnce() {
        var governor = CueGovernor()
        var played: [Double] = []
        for step in 0..<70 {
            let time = Double(step) * 0.113
            if governor.admit(cue("affect_on"), at: time) != .drop { played.append(time) }
        }
        #expect(played == [0.0])
        // A pause of a full gap starts the next run.
        let afterPause = 69 * 0.113 + CueGovernor.minimumGap
        #expect(governor.admit(cue("affect_on"), at: afterPause) == .play)
    }

    @Test("different events inside the gap both play")
    func differentEventsPlay() {
        var governor = CueGovernor()
        #expect(governor.admit(cue("tell"), at: 0.0) == .play)
        #expect(governor.admit(cue("gossip"), at: 0.01) == .play)
    }

    @Test("a plugin's event-less cue is limited by its file")
    func eventlessKeyedByFile() {
        var governor = CueGovernor()
        #expect(governor.admit(cue(nil, file: "target_nearby.wav"), at: 0.0) == .play)
        #expect(governor.admit(cue(nil, file: "target_nearby.wav"), at: 0.1) == .drop)
        #expect(governor.admit(cue(nil, file: "other.wav"), at: 0.1) == .play)
        // An event named like a file doesn't collide with it.
        #expect(governor.admit(cue("target_nearby.wav"), at: 0.1) == .play)
    }

    @Test("the sixth concurrent cue replaces the oldest; a finished cue frees its slot")
    func capReplacesOldest() {
        var governor = CueGovernor()
        for id in 1...5 {
            #expect(play(&governor, cue("event\(id)"), at: 0.0, id: id) == .play)
        }
        #expect(governor.playingCount == 5)
        #expect(play(&governor, cue("event6"), at: 0.0, id: 6) == .playReplacing(1))
        #expect(governor.playingCount == 5)
        #expect(play(&governor, cue("event7"), at: 0.0, id: 7) == .playReplacing(2))

        governor.finished(5)
        #expect(play(&governor, cue("event8"), at: 0.0, id: 8) == .play)
        #expect(governor.playingCount == 5)
    }

    @Test("finishing an unknown or already-replaced ID is harmless")
    func finishedIsIdempotent() {
        var governor = CueGovernor()
        _ = play(&governor, cue("a"), at: 0, id: 1)
        governor.finished(1)
        governor.finished(1)
        governor.finished(99)
        #expect(governor.playingCount == 0)
    }
}
