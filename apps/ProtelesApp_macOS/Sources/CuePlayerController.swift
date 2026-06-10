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
@MainActor
final class CuePlayerController: NSObject, AVAudioPlayerDelegate {
    private static let log = Logger(subsystem: "com.proteles", category: "CuePlayer")

    /// Players retained until they report finished (AVAudioPlayer stops when
    /// released, so fire-and-forget needs the strong reference).
    private var active: [ObjectIdentifier: AVAudioPlayer] = [:]

    func play(_ cue: SoundCue) {
        guard cue.volume > 0 else { return }
        guard let url = Self.resolve(cue.file) else {
            playSystemFallback(for: cue.file)
            return
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            Self.log.debug("cue \(cue.file, privacy: .public) unplayable at \(url.path, privacy: .public)")
            return
        }
        player.volume = Float(cue.volume)
        player.pan = Float(cue.pan)
        player.delegate = self
        active[ObjectIdentifier(player)] = player
        player.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        let id = ObjectIdentifier(player) // Sendable; the player itself must not hop actors
        Task { @MainActor in
            self.active[id] = nil
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
    private func playSystemFallback(for file: String) {
        guard SoundpackConfig.load(from: try? SoundpackConfig.defaultURL()).systemSoundFallback,
              let soundName = Self.systemSoundNames[
                  ((file as NSString).lastPathComponent as NSString).deletingPathExtension
              ],
              let sound = NSSound(named: soundName)
        else {
            Self.log.debug("cue \(file, privacy: .public) not found; no fallback played")
            return
        }
        sound.play()
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
