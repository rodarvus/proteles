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
/// The behaviour set follows the researched community canon (#9): prompts
/// are **silent** by default with `tts vitals` on demand (delta speech is
/// the opt-in), typed commands interrupt stale speech (`tts enter` toggles),
/// and `tts running`/`tts focus` mirror the package's universal-TTS toggles.
/// Off by default (an accessibility opt-in): `tts on`, `tts alerts`, or
/// Settings ▸ Audio enables it. Scripts and plugins get
/// `proteles.speak(text[, interrupt])` — the `ttsSpeak` analog.
public struct TextToSpeech: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.texttospeech",
        name: "Text to Speech",
        author: "Proteles",
        version: "1.1",
        summary: "Speak game output aloud — full screen-reader mode or alerts-only. Off until enabled."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Speaks the MUD: 'everything' reads each displayed line (symbol art "
                + "stripped, gagged lines never spoken, prompts silent — `tts vitals` reads "
                + "your stats on demand); 'alerts' speaks only tells and soundpack-worthy "
                + "events. Typed commands cut stale speech (`tts enter` toggles). Tells "
                + "interrupt. Rate goes well past the macOS default — experienced "
                + "screen-reader users run 300–500 wpm. Voice and VoiceOver routing live in "
                + "Settings ▸ Audio; config is hand-editable in Settings/speech.json. "
                + "`tts setup` lists the recommended Aardwolf server-side settings.",
            commands: [
                .init(syntax: "tts on", summary: "Speak every displayed line"),
                .init(syntax: "tts alerts", summary: "Speak only tells + alert-worthy events"),
                .init(syntax: "tts off", summary: "Stop speaking lines"),
                .init(syntax: "tts vitals", summary: "Speak hp/mana/moves now (from GMCP)"),
                .init(syntax: "tts last [n]", summary: "Re-read the last line(s) of output"),
                .init(syntax: "tts say <text>", summary: "Speak something now (jumps the queue)"),
                .init(syntax: "tts stop", summary: "Stop talking and flush the queue"),
                .init(syntax: "tts enter", summary: "Toggle: typed commands cut stale speech"),
                .init(syntax: "tts running", summary: "Toggle: quiet while speedwalking"),
                .init(syntax: "tts focus", summary: "Toggle: quiet when Proteles isn't frontmost"),
                .init(syntax: "tts prompts off|delta", summary: "Prompts: silent, or speak changed vitals"),
                .init(syntax: "tts rate <wpm>", summary: "Speaking rate (80-600 words/minute)"),
                .init(syntax: "tts voice <name|default>", summary: "Pick the speaking voice"),
                .init(syntax: "tts setup", summary: "Recommended Aardwolf settings for speech play"),
                .init(syntax: "tts", summary: "Show current TTS status")
            ]
        )
    }

    public internal(set) var config: SpeechConfig
    let configURL: URL?
    /// Whether install() has run before, so re-installs (Settings edits
    /// reload the plugin) can tell a mode CHANGE from a rate tweak.
    var hasInstalled = false
    /// Cached GMCP vitals for `tts vitals` (the MUSH-Z alt+h/m/v pattern:
    /// on-demand stat queries instead of a spoken prompt). Reuses the
    /// prompt-vitals value type — same three components.
    var vitals = PromptVitals()
    var maxVitals = PromptVitals()

    public init(configURL: URL? = try? SpeechConfig.defaultURL()) {
        self.configURL = configURL
        config = SpeechConfig.load(from: configURL)
    }

    /// Re-read config and push the policy + a config reload — runs on
    /// register and re-enable, so Settings edits land via plugin reload.
    /// Speaks a confirmation when speech comes up enabled (app launch) or a
    /// Settings change flips the mode — the command path already confirms,
    /// and a VI user toggling a control they can't see needs the same
    /// feedback (upstream's plugin announces on install). Rate/voice-only
    /// reloads stay quiet.
    public mutating func install() -> [ScriptEffect] {
        let previousMode: SpeechMode? = hasInstalled ? config.mode : nil
        hasInstalled = true
        config = SpeechConfig.load(from: configURL)
        var effects: [ScriptEffect] = [.setSpeechPolicy(config.policy), .speechConfigChanged]
        if config.mode != .off, previousMode != config.mode {
            effects.append(.speak(
                text: "Text to speech \(config.mode == .alerts ? "alerts" : "on")",
                interrupt: true
            ))
        }
        return effects
    }

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        switch package.lowercased() {
        case "char.vitals":
            let values = Self.intValues(in: json)
            vitals = PromptVitals(
                hp: values["hp"] ?? vitals.hp,
                mana: values["mana"] ?? vitals.mana,
                moves: values["moves"] ?? vitals.moves
            )
        case "char.maxstats":
            let values = Self.intValues(in: json)
            maxVitals = PromptVitals(
                hp: values["maxhp"] ?? maxVitals.hp,
                mana: values["maxmana"] ?? maxVitals.mana,
                moves: values["maxmoves"] ?? maxVitals.moves
            )
        default:
            break
        }
        return []
    }

    /// Tolerant GMCP number extraction (Aardwolf sends ints; be lenient
    /// about strings).
    static func intValues(in json: String) -> [String: Int] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return [:] }
        return object.compactMapValues { value in
            if let number = value as? Int { return number }
            if let text = value as? String { return Int(text) }
            return nil
        }
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
            ?? dispatchSettings(subcommand: parts[0].lowercased(), argument: argument)
    }

    /// The speak-now / review subcommands. Nil falls through to the
    /// settings dispatch (split for the complexity budget).
    private mutating func dispatch(subcommand: String, argument: String) -> [ScriptEffect]? {
        switch subcommand {
        case "say": argument.isEmpty ? usage() : [.speak(text: argument, interrupt: true)]
        case "last": speakLast(argument.isEmpty ? "1" : argument)
        case "vitals", "vit": speakVitals()
        case "stop": [.stopSpeaking]
        case "help": helpNotes()
        case "setup": setupNotes()
        default: nil
        }
    }

    private mutating func dispatchSettings(subcommand: String, argument: String) -> [ScriptEffect] {
        switch subcommand {
        case "mode": if argument.isEmpty { status() } else { usage() }
        case "rate": setRate(argument)
        case "voice": setVoice(argument)
        case "prompts", "prompt": setPromptSpeech(argument)
        case "enter": toggleEnterInterrupts()
        case "running": toggleQuietWhileRunning()
        case "focus": toggleQuietWhenUnfocused()
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

    // MARK: - Speak-now subcommands

    private func speakLast(_ value: String) -> [ScriptEffect] {
        let count = min(max(Int(value) ?? 1, 1), SessionController.recentDisplayedLimit)
        return [.speakRecentOutput(count: count)]
    }

    /// On-demand vitals (the canon replacement for spoken prompts). Speaks
    /// even when line speech is off — an explicit request is an answer.
    private func speakVitals() -> [ScriptEffect] {
        guard vitals.hp != nil || vitals.mana != nil || vitals.moves != nil else {
            return [.speak(text: "No vitals yet.", interrupt: true)]
        }
        func part(_ label: String, _ current: Int?, _ max: Int?) -> String? {
            guard let current else { return nil }
            if let max, max > 0 { return "\(label) \(current) of \(max)" }
            return "\(label) \(current)"
        }
        let text = [
            part("hp", vitals.hp, maxVitals.hp),
            part("mana", vitals.mana, maxVitals.mana),
            part("moves", vitals.moves, maxVitals.moves)
        ].compactMap(\.self).joined(separator: ", ")
        return [.speak(text: text, interrupt: true)]
    }

    // MARK: - Settings subcommands

    private mutating func setMode(_ mode: SpeechMode) -> [ScriptEffect] {
        config.mode = mode
        config.save(to: configURL)
        let description = switch mode {
        case .off: "off."
        case .alerts: "on — speaking tells and alert-worthy events."
        case .everything: "on — speaking every displayed line."
        }
        var effects: [ScriptEffect] = [
            .setSpeechPolicy(config.policy),
            Self.note("Text-to-speech is \(description)")
        ]
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

    private mutating func setPromptSpeech(_ value: String) -> [ScriptEffect] {
        switch value.lowercased() {
        case "off":
            config.promptSpeech = .off
        case "delta", "changes":
            config.promptSpeech = .delta
        case "":
            let current = config.promptSpeech == .off ? "silent" : "spoken as changed vitals"
            return [Self.note("Prompts are \(current) — `tts prompts off|delta`. "
                    + "`tts vitals` reads stats any time.")]
        default:
            return [Self.note("Usage: tts prompts off|delta")]
        }
        config.save(to: configURL)
        let description = config.promptSpeech == .off
            ? "silent (use `tts vitals` on demand)."
            : "spoken as changed vitals only."
        return [.setSpeechPolicy(config.policy), Self.note("Prompts are now \(description)")]
    }

    private mutating func toggleEnterInterrupts() -> [ScriptEffect] {
        config.enterInterrupts.toggle()
        config.save(to: configURL)
        return [.setSpeechPolicy(config.policy), Self.note(config.enterInterrupts
                ? "Typed commands now cut stale speech."
                : "Typed commands no longer interrupt speech.")]
    }

    private mutating func toggleQuietWhileRunning() -> [ScriptEffect] {
        config.quietWhileRunning.toggle()
        config.save(to: configURL)
        return [.setSpeechPolicy(config.policy), Self.note(config.quietWhileRunning
                ? "Speech is now quiet while speedwalking."
                : "Speech now stays on while speedwalking.")]
    }

    private mutating func toggleQuietWhenUnfocused() -> [ScriptEffect] {
        config.quietWhenUnfocused.toggle()
        config.save(to: configURL)
        return [.speechConfigChanged, Self.note(config.quietWhenUnfocused
                ? "Speech is now quiet when Proteles isn't the active app."
                : "Speech now stays on when Proteles loses focus.")]
    }

    // MARK: - Output

    private func status() -> [ScriptEffect] {
        let mode = switch config.mode {
        case .off: "off"
        case .alerts: "alerts-only"
        case .everything: "everything"
        }
        return [Self.note(
            "TTS: \(mode), \(config.wordsPerMinute) wpm, voice \(config.voice ?? "default"), "
                + "routing \(config.voiceOverRouting ? "VoiceOver" : "app voice"), prompts "
                + "\(config.promptSpeech.rawValue). `tts help` for commands."
        )]
    }

    private func usage() -> [ScriptEffect] {
        [Self.note("Usage: tts on|alerts|off | vitals | last [n] | say <text> | stop | "
                + "enter | running | focus | prompts off|delta | rate <wpm> | voice <name> | setup")]
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

    /// The Aardwolf server-side settings the VI community recommends (#9
    /// research: aardwolf.com Main/VI + help spamreduce/blindmode/prompt).
    /// Informational only — several are toggles whose current state we can't
    /// see, so applying them blind could flip them the wrong way.
    private func setupNotes() -> [ScriptEffect] {
        let lines = [
            "Recommended Aardwolf settings for speech play (type each yourself):",
            "  prompt                - turn the repeating prompt off (tts vitals replaces it)",
            "  spamreduce bprompt    - battle prompt once per round instead of every line",
            "  spamreduce silentrun  - no room names while speedwalking",
            "  nospam / battlespam   - trim combat spam (see: help spamreduce)",
            "  brief                 - room descriptions only on first visit",
            "  catchtell             - queue tells for replay instead of mid-combat",
            "  blindmode 1           - simplified command output + VI room descriptions",
            "  channel history       - <channel>-h N replays the last N messages",
            "Also consider turning off automap and maprun (help map)."
        ]
        return lines.map { Self.note($0) }
    }

    static func note(_ message: String) -> ScriptEffect {
        .colourNote([
            NoteSegment(text: "[", foreground: "#4682B4"),
            NoteSegment(text: "TTS", foreground: "#3CB371"),
            NoteSegment(text: "] " + message, foreground: "#4682B4")
        ])
    }
}
