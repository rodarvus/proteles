import Foundation

/// The native Aardwolf soundpack (#10) — the port of Pwar's
/// `Aardwolf_Soundpack` (the package plugin that entered via the VI
/// integration, PR #251). ``SoundEventClassifier`` carries the transcribed
/// event vocabulary (48 line triggers + the `comm.channel`/`comm.quest`/
/// `comm.repop` GMCP keying); this plugin owns the user's config
/// (`Settings/soundpack.json`, hand-editable) and the `spset` command
/// surface, and emits ``ScriptEffect/playSound(file:volume:pan:)`` cues the
/// app's player renders.
///
/// **Muted by default**, like the reference (`sp_mute_toggle = "1"`) —
/// `spmute` (or Settings ▸ Audio) turns it on. Volumes follow the reference
/// model exactly: per-event 0–100 (0 disables the event), capped by the
/// global volume, then the percent→dB→linear curve (``SoundVolume``) so cues
/// players tuned in MUSHclient sound identical.
///
/// **Dropped from the reference (security):** the remote `!!SOUND(url)`
/// HTTP download, `spallow`/`spdeny`, and `savesound`. A `!!SOUND(name.wav)`
/// in a channel message degrades to *local-file-only*: it plays only if the
/// named file already exists in your Sounds folder (gated by the
/// `remote_sound` event volume); URLs are ignored.
public struct Soundpack: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.soundpack",
        name: "Soundpack",
        author: "Proteles (after Pwar's Aardwolf_Soundpack)",
        version: "1.0",
        summary: "Event sounds: channels, quests, level-ups, scry alerts and more. Muted until enabled."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Plays a distinct cue per game event (tells, quest ready, level-up, scry, …) — "
                + "the Aardwolf soundpack, natively. Your own files in ~/Documents/Proteles/Sounds/ "
                + "always win; missing cues fall back to the bundled set, then a system alert. "
                + "Muted by default: `spmute` to enable. Config is hand-editable in "
                + "Settings/soundpack.json. Remote !!SOUND(url) downloads are not supported "
                + "(local files by name still play).",
            commands: [
                .init(syntax: "spset", summary: "List events: volume, panning, file, description"),
                .init(syntax: "spset <event>", summary: "Show one event's settings"),
                .init(syntax: "spset <event> volume <0-100>", summary: "Set event volume (0 disables)"),
                .init(syntax: "spset <event> panning <-100..100>", summary: "Set stereo pan"),
                .init(syntax: "spset <event> wav <file|default>", summary: "Set or reset the cue file"),
                .init(syntax: "sptog <event>|all", summary: "Toggle event(s) on/off"),
                .init(syntax: "spvol [0-100]", summary: "Show or set the global volume cap"),
                .init(syntax: "spmute", summary: "Toggle the whole soundpack on/off"),
                .init(syntax: "spdebug", summary: "Toggle event-fire debug notes"),
                .init(syntax: "sphelp", summary: "Show soundpack help")
            ]
        )
    }

    // MARK: - State

    public internal(set) var config: SoundpackConfig
    /// Where config persists; injectable for tests (`nil` = never touch disk).
    let configURL: URL?
    /// Own character name (from `char.base`), so a `!!SOUND` we sent isn't
    /// replayed to ourselves off the channel echo (reference behaviour).
    var selfName = ""

    public init(configURL: URL? = try? SoundpackConfig.defaultURL()) {
        self.configURL = configURL
        config = SoundpackConfig.load(from: configURL)
    }

    /// Re-read config on (re-)enable, so hand-edits to soundpack.json land
    /// on plugin toggle without an app restart. Mirrors the master mute to
    /// the session, which gates EVERY `.playSound` cue on it — so "Play
    /// event sounds: off" also silences S&D's direct cues and shim plugins.
    public mutating func install() -> [ScriptEffect] {
        config = SoundpackConfig.load(from: configURL)
        return [.setSoundCuesMuted(config.muted)]
    }

    // MARK: - Event sources

    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        guard !config.muted else { return .init() }
        var effects: [ScriptEffect] = []
        for event in SoundEventClassifier.events(forLine: line.text) {
            effects.append(contentsOf: cueEffects(for: event))
        }
        return .init(effects: effects)
    }

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        onGMCP(package: package, json: json, context: GMCPDispatchContext())
    }

    public mutating func onGMCP(
        package: String, json: String, context: GMCPDispatchContext
    ) -> [ScriptEffect] {
        switch package.lowercased() {
        case "char.base":
            // Track own name even while muted, so unmuting works mid-session.
            if let name = Self.baseName(in: json) { selfName = name }
            return []
        case "comm.channel":
            // A Chat Echo-muted speaker plays nothing — neither the channel
            // cue nor an inline !!SOUND — exactly the reference's early
            // return after `CallPlugin(chat, "checkIfMuted", player)` (#55).
            guard !config.muted, !context.speakerMuted,
                  let comm = try? JSONDecoder().decode(CommChannel.self, from: Data(json.utf8))
            else { return [] }
            var effects = inlineSoundEffects(in: comm)
            if let event = SoundEventClassifier.channelEvent(chan: comm.chan) {
                effects.append(contentsOf: cueEffects(for: event))
            }
            return effects
        case "comm.quest":
            guard !config.muted,
                  let data = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let action = data["action"] as? String,
                  let event = SoundEventClassifier.questEvent(action: action)
            else { return [] }
            return cueEffects(for: event)
        case "comm.repop":
            guard !config.muted else { return [] }
            return cueEffects(for: SoundEventClassifier.zoneRepopEvent)
        default:
            return []
        }
    }

    // MARK: - Cue math (the reference's TriggerEvent)

    /// The `.playSound` (+ optional debug note) for one fired event, or
    /// nothing when the event is disabled / unknown. Volume = per-event
    /// percent capped by the global, through the percent→dB→linear curve.
    func cueEffects(for event: String) -> [ScriptEffect] {
        let volume = config.volume(for: event)
        guard volume > 0, let file = config.file(for: event) else {
            return config.debug && config.volume(for: event) == 0
                ? [Self.debugNote("Event \(event) has fired, but event volume is set to 0. Ignoring.")]
                : []
        }
        let effective = min(volume, config.globalVolume)
        var effects: [ScriptEffect] = []
        if config.debug { effects.append(Self.debugNote("Event \(event) has fired!")) }
        effects.append(.playSound(
            file: file,
            volume: SoundVolume.linearGain(forPercent: Double(effective)),
            pan: SoundVolume.pan(forMushPan: Double(config.pan(for: event)))
        ))
        return effects
    }

    /// A settings-change confirmation cue (the reference's
    /// `PlaySettingChanged`): `channel_on.wav` at the global volume.
    func confirmationCue() -> ScriptEffect {
        .playSound(
            file: "channel_on.wav",
            volume: SoundVolume.linearGain(forPercent: Double(config.globalVolume)),
            pan: 0
        )
    }

    // MARK: - !!SOUND (local-file-only)

    /// A `!!SOUND(name)` inside a channel message: play the named file if
    /// it's local (the cue player resolves it; missing files are silent).
    /// URLs are dropped — the reference's HTTP download is a security
    /// non-starter — and our own sends are skipped (we already played them
    /// on the way out). Gated by the `remote_sound` event volume.
    func inlineSoundEffects(in comm: CommChannel) -> [ScriptEffect] {
        guard comm.player != selfName,
              let name = Self.inlineSoundName(in: AardwolfColor.stripped(comm.msg))
        else { return [] }
        guard !name.lowercased().hasPrefix("http") else {
            return config.debug
                ?
                [Self
                    .debugNote("Ignoring remote !!SOUND URL from \(comm.player) (downloads not supported).")]
                : []
        }
        let volume = config.volume(for: "remote_sound")
        guard volume > 0 else { return [] }
        let effective = min(volume, config.globalVolume)
        return [.playSound(
            file: name,
            volume: SoundVolume.linearGain(forPercent: Double(effective)),
            pan: 0
        )]
    }

    /// The character name in a `char.base` payload, if present.
    static func baseName(in json: String) -> String? {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return object?["name"] as? String
    }

    /// Extract the `!!SOUND(…)` payload from a stripped message, if any.
    static func inlineSoundName(in text: String) -> String? {
        guard let open = text.range(of: "!!SOUND("),
              let close = text[open.upperBound...].firstIndex(of: ")")
        else { return nil }
        let name = String(text[open.upperBound..<close]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - Output helpers

    /// `[Soundpack] message` in the reference's SteelBlue/SeaGreen scheme.
    static func note(_ message: String) -> ScriptEffect {
        .colourNote([
            NoteSegment(text: "[", foreground: "#4682B4"),
            NoteSegment(text: "Soundpack", foreground: "#3CB371"),
            NoteSegment(text: "] " + message, foreground: "#4682B4")
        ])
    }

    static func errorNote(_ message: String) -> ScriptEffect {
        .colourNote([
            NoteSegment(text: "[", foreground: "#4682B4"),
            NoteSegment(text: "Soundpack", foreground: "#3CB371"),
            NoteSegment(text: "] ", foreground: "#4682B4"),
            NoteSegment(text: "Error: " + message, foreground: "#FF0000")
        ])
    }

    static func debugNote(_ message: String) -> ScriptEffect {
        .colourNote([
            NoteSegment(text: "[dbg_sp] ", foreground: "#808000"),
            NoteSegment(text: message, foreground: "#3CB371")
        ])
    }

    /// Persist the current config (no-op with a nil URL).
    func saveConfig() {
        config.save(to: configURL)
    }
}
