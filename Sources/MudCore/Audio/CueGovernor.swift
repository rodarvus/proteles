import Foundation

/// Playback discipline for sound cues (S1 step 3, #83): which cues play, and
/// which playing cue makes room. Pure policy — the platform player owns one,
/// asks it before every play, and reports when a sound ends. Mixing policy
/// lives in MudCore so the macOS and iOS players stay thin (D-127).
///
/// Two rules, set from a month of recordings
/// (`docs/plans/S1_ITEM3_PROPOSAL.md` §2):
///
/// - **Rate limit — a run of repeats plays once:** a cue whose key (its event,
///   else its file) last *arrived* less than ``minimumGap`` ago is dropped, and
///   every arrival restarts the gap. So a run of repeats plays at its start
///   and not again until it pauses for ``minimumGap``. Bursts are one event
///   repeated — a stack of loot plays `bonus_item` sixteen times in one
///   packet, a spellup recast `affect_on` sixty times eight-to-the-second —
///   and the run is one thing happening. (The first build limited a run to
///   one cue per gap instead; live, a recast still sounded like every spell.)
/// - **Concurrency cap:** at most ``maximumConcurrent`` cues at once, the
///   number MUSHclient plays in the soundpack's mode. At the cap the oldest
///   playing cue is stopped for the new one: the newest cue is the current
///   news. With the rate limit in place the cap never triggered in the
///   recordings; it is the backstop.
public struct CueGovernor: Sendable {
    /// The player's handle for one playing cue.
    public typealias PlaybackID = Int

    public enum Decision: Sendable, Equatable {
        /// Play it.
        case play
        /// Stop the playing cue with this ID, then play it.
        case playReplacing(PlaybackID)
        /// Don't play it: the same key played too recently.
        case drop
    }

    public static let minimumGap: TimeInterval = 0.25
    public static let maximumConcurrent = 5

    /// When each key last *arrived*, played or dropped: a run of repeats
    /// keeps restarting its own gap.
    private var lastArrived: [String: TimeInterval] = [:]
    /// Playing cues, oldest first.
    private var playing: [PlaybackID] = []

    public init() {}

    /// The key a cue is rate-limited on: its event, or its file when a
    /// plugin played it directly. Every trigger file sound shares one event
    /// (`trigger_sound`), so those key on their file: two different files are
    /// two things happening (S1 step 4).
    static func key(for cue: SoundCue) -> String {
        guard let event = cue.event, event != TriggerSound.triggerSoundEvent else {
            return "file:" + cue.file
        }
        return event
    }

    /// Decide on `cue` arriving at `time` (seconds, any monotonic clock). On
    /// `.play` or `.playReplacing`, the caller starts it and reports it with
    /// ``started(_:)``; on `.playReplacing` the named cue's slot is already
    /// freed.
    public mutating func admit(_ cue: SoundCue, at time: TimeInterval) -> Decision {
        let key = Self.key(for: cue)
        let last = lastArrived[key]
        lastArrived[key] = time
        if let last, time - last < Self.minimumGap { return .drop }
        guard playing.count >= Self.maximumConcurrent else { return .play }
        return .playReplacing(playing.removeFirst())
    }

    /// The player started a cue under `id`.
    public mutating func started(_ id: PlaybackID) {
        playing.append(id)
    }

    /// The cue `id` finished (or was stopped); its slot is free.
    public mutating func finished(_ id: PlaybackID) {
        playing.removeAll { $0 == id }
    }

    /// How many cues are playing.
    public var playingCount: Int {
        playing.count
    }
}
