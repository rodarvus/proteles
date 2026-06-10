import Foundation

/// Native text-to-speech (#9, D-41) — the accessibility surface for VI
/// Aardwolf players (and spoken alerts for everyone else). This plugin owns
/// the `tts` command surface and the hand-editable `Settings/speech.json`;
/// the *speaking* happens elsewhere: ``SessionController`` runs displayed
/// lines through ``SpeechFilter`` (so gagged spam never talks) and the app's
/// `SpeechController` renders requests via `AVSpeechSynthesizer` or — with
/// `voiceOverRouting` on — VoiceOver announcements (speech + braille via the
/// user's assistive settings).
///
/// Off by default (an accessibility opt-in): `tts on`, `tts alerts`, or
/// Settings ▸ Audio enables it. Scripts and plugins get
/// `proteles.speak(text[, interrupt])` — the `ttsSpeak` analog.
public struct TextToSpeech: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.texttospeech",
        name: "Text to Speech",
        author: "Proteles",
        version: "1.0",
        summary: "Speak game output aloud — full screen-reader mode or alerts-only. Off until enabled."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Speaks the MUD: 'everything' reads each displayed line (symbol art "
                + "stripped, gagged lines never spoken); 'alerts' speaks only tells and "
                + "soundpack-worthy events (level-ups, quest events, scry, …). Tells interrupt "
                + "the current utterance. Rate goes well past the macOS default — experienced "
                + "screen-reader users run 300–500 wpm. Voice and VoiceOver routing live in "
                + "Settings ▸ Audio; config is hand-editable in Settings/speech.json.",
            commands: [
                .init(syntax: "tts on", summary: "Speak every displayed line"),
                .init(syntax: "tts alerts", summary: "Speak only tells + alert-worthy events"),
                .init(syntax: "tts off", summary: "Stop speaking lines"),
                .init(syntax: "tts rate <wpm>", summary: "Speaking rate (80-600 words/minute)"),
                .init(syntax: "tts voice <name|default>", summary: "Pick the speaking voice"),
                .init(syntax: "tts say <text>", summary: "Speak something now (jumps the queue)"),
                .init(syntax: "tts last [n]", summary: "Re-read the last line(s) of output"),
                .init(syntax: "tts stop", summary: "Stop talking and flush the queue"),
                .init(syntax: "tts", summary: "Show current TTS status")
            ]
        )
    }

    public internal(set) var config: SpeechConfig
    let configURL: URL?

    public init(configURL: URL? = try? SpeechConfig.defaultURL()) {
        self.configURL = configURL
        config = SpeechConfig.load(from: configURL)
    }

    /// Re-read config and push the mode + a config reload — runs on
    /// register and re-enable, so Settings edits land via plugin reload.
    public mutating func install() -> [ScriptEffect] {
        config = SpeechConfig.load(from: configURL)
        return [.setSpeechMode(config.mode), .speechConfigChanged]
    }

    public mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased() == "tts" || trimmed.lowercased().hasPrefix("tts ") else { return nil }
        let rest = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return status() }
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        if let mode = Self.mode(forSubcommand: parts[0], argument: argument) {
            return setMode(mode)
        }
        return dispatch(subcommand: parts[0].lowercased(), argument: argument)
    }

    /// The non-mode subcommands (split from ``handleCommand(_:)`` for the
    /// complexity budget).
    private mutating func dispatch(subcommand: String, argument: String) -> [ScriptEffect] {
        switch subcommand {
        case "mode": if argument.isEmpty { status() } else { usage() }
        case "rate": setRate(argument)
        case "voice": setVoice(argument)
        case "say": if argument.isEmpty { usage() } else { [.speak(text: argument, interrupt: true)] }
        case "last": speakLast(argument.isEmpty ? "1" : argument)
        case "stop": [.stopSpeaking]
        case "help": helpNotes()
        default: usage()
        }
    }

    /// `tts on|alerts|off` (and `tts mode <x>`) → the target mode, nil for
    /// non-mode subcommands. Split from ``handleCommand(_:)`` for the
    /// complexity budget.
    private static func mode(forSubcommand subcommand: String, argument: String) -> SpeechMode? {
        let word: String = switch subcommand.lowercased() {
        case "mode": argument.lowercased()
        default: subcommand.lowercased()
        }
        return switch word {
        case "on", "all", "everything": .everything
        case "alerts", "alert": .alerts
        case "off": .off
        default: nil
        }
    }

    // MARK: - Subcommands

    private mutating func setMode(_ mode: SpeechMode) -> [ScriptEffect] {
        config.mode = mode
        config.save(to: configURL)
        let description = switch mode {
        case .off: "off."
        case .alerts: "on — speaking tells and alert-worthy events."
        case .everything: "on — speaking every displayed line."
        }
        var effects: [ScriptEffect] = [.setSpeechMode(mode), Self.note("Text-to-speech is \(description)")]
        if mode == .off {
            effects.append(.stopSpeaking)
        } else {
            effects.append(.speak(
                text: "Text to speech \(mode == .alerts ? "alerts" : "on")",
                interrupt: true
            ))
        }
        return effects
    }

    private mutating func setRate(_ value: String) -> [ScriptEffect] {
        guard let wpm = Int(value), (80...600).contains(wpm) else {
            return value.isEmpty
                ? [Self.note("Speaking rate is \(config.wordsPerMinute) words per minute.")]
                : [Self.note("Rate must be 80-600 words per minute.")]
        }
        config.wordsPerMinute = wpm
        config.save(to: configURL)
        return [
            .speechConfigChanged,
            Self.note("Speaking rate set to \(wpm) words per minute."),
            .speak(text: "This is \(wpm) words per minute.", interrupt: true)
        ]
    }

    private mutating func setVoice(_ value: String) -> [ScriptEffect] {
        guard !value.isEmpty else {
            return [Self.note("Voice: \(config.voice ?? "system default"). "
                    + "Set with `tts voice <name>` or browse in Settings ▸ Audio.")]
        }
        config.voice = value.lowercased() == "default" ? nil : value
        config.save(to: configURL)
        return [
            .speechConfigChanged,
            Self.note("Voice set to \(config.voice ?? "the system default")."),
            .speak(text: "This is my voice.", interrupt: true)
        ]
    }

    private func speakLast(_ value: String) -> [ScriptEffect] {
        let count = min(max(Int(value) ?? 1, 1), SessionController.recentDisplayedLimit)
        return [.speakRecentOutput(count: count)]
    }

    private func status() -> [ScriptEffect] {
        let mode = switch config.mode {
        case .off: "off"
        case .alerts: "alerts-only"
        case .everything: "everything"
        }
        return [Self.note(
            "TTS: \(mode), \(config.wordsPerMinute) wpm, voice \(config.voice ?? "default"), "
                + "routing \(config.voiceOverRouting ? "VoiceOver" : "app voice"). `tts help` for commands."
        )]
    }

    private func usage() -> [ScriptEffect] {
        [Self.note("Usage: tts on|alerts|off | rate <wpm> | voice <name> | say <text> | last [n] | stop")]
    }

    private func helpNotes() -> [ScriptEffect] {
        var effects = [Self.note("Text to Speech — commands:")]
        for command in help.commands {
            effects.append(.colourNote([
                NoteSegment(text: "  " + Soundpack.pad(command.syntax, 28), foreground: "#20B2AA"),
                NoteSegment(text: command.summary, foreground: "#4682B4")
            ]))
        }
        return effects
    }

    static func note(_ message: String) -> ScriptEffect {
        .colourNote([
            NoteSegment(text: "[", foreground: "#4682B4"),
            NoteSegment(text: "TTS", foreground: "#3CB371"),
            NoteSegment(text: "] " + message, foreground: "#4682B4")
        ])
    }
}
