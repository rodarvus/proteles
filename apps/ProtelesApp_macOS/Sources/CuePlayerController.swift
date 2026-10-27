import AppKit
import AVFoundation
import MudCore
import os

/// The app's one cue player (#10): consumes ``SessionController/soundCues``
/// (`.playSound` effects from the Soundpack plugin, the compat shim, and the
/// S&D host) and renders each as an `AVAudioPlayer` one-shot. This is the
/// single audio chokepoint — future TTS ducking coordinates here.
///
/// File resolution, per cue:
/// 1. An absolute path plays as-is if it exists (a shim plugin passing
///    `GetInfo(74) .. file`); otherwise its basename falls through.
/// 2. `~/Documents/Proteles/Sounds/<file>` — the user's own cues (their
///    MUSHclient import or manual drops) always win.
/// 3. The bundled `DefaultSounds/<name>.wav` — the CC0 out-of-the-box set,
///    named after the MUSHclient defaults (see PROVENANCE.md).
/// 4. A mapped macOS system alert (`NSSound(named:)`) for known default cue
///    names, when `soundpack.json` has `systemSoundFallback` on.
/// 5. Silence + an os_log debug line (a missing file must never error-spam).
///
/// Before any of that, every cue passes the ``CueGovernor`` (S1 step 3): the
/// same event inside 0.25 s is dropped, and at five sounds playing the oldest
/// is stopped for the new one. The policy is MudCore's; this player only
/// reports what starts and finishes.
@MainActor
final class CuePlayerController: NSObject, AVAudioPlayerDelegate {
    private static let log = Logger(subsystem: "com.proteles", category: "CuePlayer")

    /// Players retained until they report finished (AVAudioPlayer stops when
    /// released, so fire-and-forget needs the strong reference), keyed by the
    /// governor's playback ID.
    private var active: [CueGovernor.PlaybackID: AVAudioPlayer] = [:]
    /// Player → playback ID, for the finish callback.
    private var playbackIDs: [ObjectIdentifier: CueGovernor.PlaybackID] = [:]
    private var governor = CueGovernor()
    private var nextPlaybackID: CueGovernor.PlaybackID = 0

    /// How long a system-alert fallback holds its slot: `NSSound` has no
    /// finish callback here, and the alerts are short.
    private static let systemAlertSlot: Duration = .seconds(1)

    func play(_ cue: SoundCue) {
        guard cue.volume > 0 else { return }
        switch governor.admit(cue, at: ProcessInfo.processInfo.systemUptime) {
        case .drop:
            Self.log.debug("cue \(cue.event ?? cue.file, privacy: .public) dropped: repeated inside the gap")
            return
        case .playReplacing(let oldest):
            stop(oldest)
        case .play:
            break
        }
        let id = nextPlaybackID
        nextPlaybackID += 1
        guard let url = Self.resolve(cue.file) else {
            if playSystemFallback(for: cue.file) { holdSlot(id, for: Self.systemAlertSlot) }
            return
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            Self.log.debug("cue \(cue.file, privacy: .public) unplayable at \(url.path, privacy: .public)")
            return
        }
        player.volume = Float(cue.volume)
        player.pan = Float(cue.pan)
        player.delegate = self
        active[id] = player
        playbackIDs[ObjectIdentifier(player)] = id
        governor.started(id)
        player.play()
    }

    /// Stop a playing cue the governor chose to replace. `stop()` sends no
    /// finish callback, so the bookkeeping is done here.
    private func stop(_ id: CueGovernor.PlaybackID) {
        guard let player = active.removeValue(forKey: id) else { return }
        playbackIDs[ObjectIdentifier(player)] = nil
        player.stop()
    }

    /// Count a sound with no finish callback as playing for `duration`.
    private func holdSlot(_ id: CueGovernor.PlaybackID, for duration: Duration) {
        governor.started(id)
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            self.governor.finished(id)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        let key = ObjectIdentifier(player) // Sendable; the player itself must not hop actors
        Task { @MainActor in
            guard let id = self.playbackIDs.removeValue(forKey: key) else { return }
            self.active[id] = nil
            self.governor.finished(id)
        }
    }

    // MARK: - Resolution

    /// Resolve a cue file through the user's Sounds dir, then the bundled
    /// defaults. Returns nil when nothing exists (system fallback's turn).
    static func resolve(_ file: String) -> URL? {
        let fileManager = FileManager.default
        if file.hasPrefix("/") {
            if fileManager.fileExists(atPath: file) { return URL(fileURLWithPath: file) }
            // Fall through with the basename — an absolute Sounds-dir path
            // for a missing file can still hit the bundled default.
        }
        let name = (file as NSString).lastPathComponent
        if let sounds = try? ProtelesPaths.soundsDirectory() {
            // Relative subpaths (e.g. the reference's `saved/x.wav`) resolve
            // against the Sounds dir as written; bare names directly.
            let candidate = file.hasPrefix("/")
                ? sounds.appendingPathComponent(name)
                : sounds.appendingPathComponent(file)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        let stem = (name as NSString).deletingPathExtension
        return Bundle.main.url(forResource: stem, withExtension: "wav", subdirectory: "DefaultSounds")
    }

    /// Tier 4: a mapped system alert for a known default cue name — gated by
    /// the (rare) miss path, so re-reading the config is cheap and always
    /// current. Unknown names (a user's custom file that went missing) stay
    /// silent by design.
    /// Returns whether an alert played.
    @discardableResult
    private func playSystemFallback(for file: String) -> Bool {
        guard SoundpackConfig.load(from: try? SoundpackConfig.defaultURL()).systemSoundFallback,
              let soundName = Self.systemSoundNames[
                  ((file as NSString).lastPathComponent as NSString).deletingPathExtension
              ],
              let sound = NSSound(named: soundName)
        else {
            Self.log.debug("cue \(file, privacy: .public) not found; no fallback played")
            return false
        }
        return sound.play()
    }

    /// Default cue stem → macOS system alert (`/System/Library/Sounds`),
    /// grouped by event character: harsh alerts Basso, achievements Hero,
    /// finds Glass, info Ping, toggles Tink, comms Pop/Purr, scry Sosumi.
    static let systemSoundNames: [String: String] = [
        "death": "Basso", "quest_warning": "Basso", "warfare": "Basso", "yell": "Basso",
        "curse": "Basso",
        "level_up": "Hero", "level_up_sh": "Hero",
        "quest_complete": "Glass", "quest_target_found": "Glass", "quest_target_killed": "Glass",
        "special_find": "Glass", "bonus_item": "Glass", "gq_win": "Glass", "cp_mob_dead": "Glass",
        "gq_mob_dead": "Glass",
        "info": "Ping", "personal_note": "Ping", "quest_ready": "Ping", "quest_start": "Ping",
        "global_quest": "Ping", "restore": "Ping", "rauction": "Ping", "auction": "Ping",
        "channel_on": "Tink", "channel_off": "Tink", "follow": "Tink", "stop_follow": "Tink",
        "zone_repop": "Submarine", "double_exp": "Submarine", "double_end": "Submarine",
        "scry": "Sosumi", "aarch_prof": "Sosumi", "manor_doorbell": "Blow",
        "tell": "Purr", "gtell": "Purr", "spouse": "Purr", "whisper": "Purr",
        "say": "Pop", "answer": "Pop", "question": "Pop", "gossip": "Pop", "gratz": "Pop",
        "gsocial": "Pop", "gametalk": "Pop", "gclan": "Pop", "clantalk": "Pop", "claninfo": "Pop",
        "ftalk": "Pop", "helper": "Pop", "immtalk": "Pop", "inform": "Pop", "ltalk": "Pop",
        "market": "Pop", "music": "Pop", "newbie": "Pop", "nobletalk": "Pop", "pokerinfo": "Pop",
        "quote": "Pop", "racetalk": "Pop", "rp": "Pop", "tech": "Pop", "tiertalk": "Pop",
        "wangrp": "Pop", "barter": "Pop", "debate": "Pop", "epic": "Pop", "gclaninfo": "Pop"
    ]
}
