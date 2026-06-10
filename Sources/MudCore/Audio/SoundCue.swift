import Foundation

/// A one-shot sound cue bound for the app's cue player (issue #10). Emitted
/// as a `.playSound` ``ScriptEffect`` by the native Soundpack plugin, the
/// compat shim's `PlaySound`, and the Search-and-Destroy host's `PlaySound`
/// (its target-nearby cues); the session re-publishes it on
/// ``SessionController/soundCues`` for the app to play (`AVAudioPlayer`).
public struct SoundCue: Sendable, Equatable {
    /// A bare filename (`tell.wav` — resolved app-side against the user's
    /// `~/Documents/Proteles/Sounds/`, then the bundled defaults) or an
    /// absolute path (a shim plugin passing `GetInfo(74) .. file`).
    public let file: String
    /// Linear gain 0…1 — the MUSHclient percent→dB curve already applied
    /// (see ``SoundVolume``), so cues sound as they did in MUSHclient.
    public let volume: Double
    /// Stereo pan: −1 full left … +1 full right.
    public let pan: Double

    public init(file: String, volume: Double, pan: Double) {
        self.file = file
        self.volume = volume
        self.pan = pan
    }
}

/// The MUSHclient soundpack volume model, transcribed from
/// `aard_soundpack.xml`'s `calc_volume`: a 0–100 percent maps to decibels as
/// `dB = 0.4·v − 40` (100% → 0 dB, 50% → −20 dB, 0% → −40 dB), which
/// MUSHclient hands to DirectSound. `AVAudioPlayer` takes *linear* gain, so
/// we convert (`10^(dB/20)`) — replicating the perceived loudness players
/// tuned their per-event volumes against.
public enum SoundVolume {
    /// Percent (0–100, clamped) → the soundpack's decibel attenuation.
    public static func decibels(forPercent percent: Double) -> Double {
        0.4 * min(max(percent, 0), 100) - 40
    }

    /// Decibels → linear gain for `AVAudioPlayer.volume` (0 dB → 1; −40 dB →
    /// 0.01; anything above 0 dB clamps to 1).
    public static func linearGain(forDecibels decibels: Double) -> Double {
        min(pow(10, decibels / 20), 1)
    }

    /// Percent (0–100) straight to linear gain via the soundpack curve.
    public static func linearGain(forPercent percent: Double) -> Double {
        linearGain(forDecibels: decibels(forPercent: percent))
    }

    /// MUSHclient pan (−100 full left … 100 full right) → `AVAudioPlayer.pan`.
    public static func pan(forMushPan pan: Double) -> Double {
        min(max(pan / 100, -1), 1)
    }

    /// `PlaySound`'s volume parameter is **decibels** (0 = full, −100 = min);
    /// MUSHclient coerces out-of-range values to 0 dB (full volume) — see
    /// `methods_sounds.cpp` (`if (Volume > 0 || Volume < -100) Volume = 0`).
    /// S&D's `PlaySound(0, file, false, 100, 0)` relies on this: 100 is out
    /// of range, so its cues play at full volume.
    public static func playSoundGain(volumeDb: Double) -> Double {
        let db = (volumeDb > 0 || volumeDb < -100) ? 0 : volumeDb
        return linearGain(forDecibels: db)
    }

    /// `PlaySound`'s pan coercion: out-of-range (beyond ±100) → centered,
    /// matching MUSHclient (`if (Pan > 100 || Pan < -100) Pan = 0`).
    public static func playSoundPan(mushPan: Double) -> Double {
        (mushPan > 100 || mushPan < -100) ? 0 : mushPan / 100
    }
}
