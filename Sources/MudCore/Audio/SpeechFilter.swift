import Foundation

/// What the TTS engine should speak (#9). The pipeline mirrors
/// notifications: ``SessionController`` runs each **displayed** line (post
/// gag/substitution — so the map, gauges, and everything plugins already
/// hide is never spoken) through this filter and yields the surviving text
/// on its speech stream; the app's `SpeechController` renders it.
public enum SpeechMode: String, Codable, Sendable {
    /// No spoken output.
    case off
    /// Only alert-worthy lines: anything the soundpack vocabulary fires on
    /// (level-ups, quest events, scry, …) plus tells. The "don't read me the
    /// whole MUD" mode.
    case alerts
    /// Every displayed line (after symbol cleanup) — the screen-reader-style
    /// experience VI players run.
    case everything
}

/// How prompt lines speak. Community canon (#9 research: Aardwolf VI page,
/// MUSH-Z, fastfinge's blueprint) is **silent** — VI players turn the prompt
/// off and query vitals on demand (`tts vitals`); the delta mode (speak only
/// changed hp/mana) is kept as an opt-in middle ground.
public enum PromptSpeechMode: String, Codable, Sendable {
    case off
    case delta
}

/// One spoken-text substitution (MUSH-Z's `subst add text==substitution`):
/// a case-insensitive literal find/replace applied to everything spoken —
/// the pronunciation fix ("gtell" → "G tell"). The replacement `!skip`
/// speech-gags any line containing `find` outright; per the ecosystem credo
/// the text stays VISIBLE — only speech skips it.
public struct SpeechSubstitution: Codable, Sendable, Equatable {
    public var find: String
    public var replace: String

    public init(find: String, replace: String) {
        self.find = find
        self.replace = replace
    }

    /// The never-speak marker (MUSH-Z's `!skip`).
    public static let skipMarker = "!skip"
}

/// The session-side speech policy, pushed as one value by the TextToSpeech
/// plugin (its commands and `Settings/speech.json` are the source of truth;
/// the session just applies it on the displayed-line path).
public struct SpeechPolicy: Sendable, Equatable {
    public var mode: SpeechMode = .off
    public var promptSpeech: PromptSpeechMode = .off
    /// Quiet while speedwalking (`char.status.state == 12`) — the package's
    /// `tts running` toggle. Off by default, as upstream.
    public var quietWhileRunning = false
    /// Sending a command cuts stale speech (mudlet-reader/MUSH-Z/NVDA canon;
    /// toggleable because MUSH-Z makes it so). On by default.
    public var enterInterrupts = true
    /// Pronunciation fixes + `!skip` speech-gags, applied in order.
    public var substitutions: [SpeechSubstitution] = []
    /// Channels whose lines are speech-muted (lowercased; VIPMud's
    /// `TALKER MUTE` — the text stays visible and in the Chat window).
    public var mutedChannels: Set<String> = []

    public init(
        mode: SpeechMode = .off,
        promptSpeech: PromptSpeechMode = .off,
        quietWhileRunning: Bool = false,
        enterInterrupts: Bool = true,
        substitutions: [SpeechSubstitution] = [],
        mutedChannels: Set<String> = []
    ) {
        self.mode = mode
        self.promptSpeech = promptSpeech
        self.quietWhileRunning = quietWhileRunning
        self.enterInterrupts = enterInterrupts
        self.substitutions = substitutions
        self.mutedChannels = mutedChannels
    }

    /// Apply the substitutions to text bound for the synthesizer: `nil`
    /// means a `!skip` rule matched (speech-gag); otherwise the text with
    /// every pronunciation fix applied (case-insensitive literal replaces).
    public func spokenText(_ text: String) -> String? {
        var result = text
        for substitution in substitutions {
            if substitution.replace == SpeechSubstitution.skipMarker {
                if result.range(of: substitution.find, options: [.caseInsensitive]) != nil {
                    return nil
                }
            } else {
                result = result.replacingOccurrences(
                    of: substitution.find, with: substitution.replace, options: [.caseInsensitive]
                )
            }
        }
        return result
    }
}

/// One speech request bound for the app's `SpeechController`, published on
/// ``SessionController/speechRequests``.
public enum SpeechRequest: Sendable, Equatable {
    /// Speak `text`; `interrupt` cuts off the current utterance (tells and
    /// `tts say` jump the queue — combat moves fast).
    case speak(text: String, interrupt: Bool)
    /// Stop speaking and flush the queue (`tts stop`).
    case stop
    /// `Settings/speech.json` changed (rate/voice/routing) — reload it.
    case reloadConfig
}

/// Pure text → speech decisions: MUD output is full of `*`/`=`/`|` art that
/// a synthesizer reads as "asterisk asterisk asterisk", so symbol runs are
/// stripped before anything is spoken. Stateless; the mode lives with the
/// caller (``SessionController``).
public enum SpeechFilter {
    public struct Decision: Sendable, Equatable {
        public let text: String
        public let interrupt: Bool
    }

    /// The decision for one displayed line under `mode`, or nil to stay
    /// silent. In `.alerts`, a line speaks only if the soundpack vocabulary
    /// fires on it or it's a tell; in `.everything`, any line that survives
    /// symbol cleanup speaks. Tells interrupt the queue in both modes.
    public static func decision(forDisplayedLine text: String, mode: SpeechMode) -> Decision? {
        guard mode != .off else { return nil }
        let spoken = normalized(text)
        guard !spoken.isEmpty else { return nil }
        let isTell = isTellLine(text)
        switch mode {
        case .off:
            return nil
        case .alerts:
            guard isTell || !SoundEventClassifier.events(forLine: text).isEmpty else { return nil }
            return Decision(text: spoken, interrupt: isTell)
        case .everything:
            return Decision(text: spoken, interrupt: isTell)
        }
    }

    /// A direct tell (or a reply confirmation) — the line VI players must
    /// not miss, so it interrupts the current utterance.
    static func isTellLine(_ text: String) -> Bool {
        text.contains(" tells you ") || text.hasPrefix("You tell ")
            || text.contains(" tells the group ")
    }

    /// Strip the decorations a synthesizer would read aloud: runs of 3+
    /// punctuation characters become a single space (separator art,
    /// `*** PRESS RETURN ***` frames, `=== headers ===`), box-drawing/block
    /// characters go unconditionally (never prose), and whitespace collapses.
    public static func normalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingRun: (character: Character, count: Int)?
        for character in text {
            if Self.isBoxDrawing(character) {
                flushRun(&result, pendingRun)
                pendingRun = nil
                result.append(" ")
            } else if Self.isDecoration(character) {
                if pendingRun?.character == character {
                    pendingRun!.count += 1
                } else {
                    flushRun(&result, pendingRun)
                    pendingRun = (character, 1)
                }
            } else {
                flushRun(&result, pendingRun)
                pendingRun = nil
                result.append(character)
            }
        }
        flushRun(&result, pendingRun)
        return result
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A run of fewer than 3 decorations is real text ("**bold**" loses
    /// little; "didn't" keeps its apostrophe); 3+ is art and becomes a space.
    private static func flushRun(_ result: inout String, _ run: (character: Character, count: Int)?) {
        guard let run else { return }
        if run.count >= 3 {
            result.append(" ")
        } else {
            result.append(String(repeating: run.character, count: run.count))
        }
    }

    /// Box-drawing + block-element + geometric-shape ranges — frame art,
    /// stripped even as single characters (a `┌` is never prose).
    private static func isBoxDrawing(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        return (0x2500...0x25FF).contains(scalar.value)
    }

    private static func isDecoration(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        return decorationScalars.contains(scalar)
    }

    private static let decorationScalars = Set<Unicode.Scalar>("*=|-_~#+<>/\\^.'`\"".unicodeScalars)
}

/// Current vitals parsed out of a prompt line (#9 live-test round 2):
/// prompts are status, not prose — instead of reading the whole line every
/// time, the session speaks only the components that *changed*. Movement is
/// deliberately absent from speech ("in practice almost never a concern" —
/// the user's words) but still parsed so a moves-only change is recognised
/// as "nothing worth saying".
public struct PromptVitals: Sendable, Equatable {
    public var hp: Int?
    public var mana: Int?
    public var moves: Int?

    public init(hp: Int? = nil, mana: Int? = nil, moves: Int? = nil) {
        self.hp = hp
        self.mana = mana
        self.moves = moves
    }
}

public extension SpeechFilter {
    /// Parse an Aardwolf-style prompt ("1180/1180hp 600/600mn 1000/1000mv …",
    /// slashes and spacing optional, any order). A line counts as a prompt
    /// only when it carries **hp plus at least one of mana/moves** — prose
    /// like "You gain 50 hp." never qualifies. Returns nil for non-prompts.
    static func promptVitals(in text: String) -> PromptVitals? {
        // Cheap prefilter before any regex: every vitals prompt contains "hp".
        guard text.range(of: "hp", options: [.caseInsensitive]) != nil,
              let hp = vitalValue(in: text, matcherIndex: 0)
        else { return nil }
        let mana = vitalValue(in: text, matcherIndex: 1)
        let moves = vitalValue(in: text, matcherIndex: 2)
        guard mana != nil || moves != nil else { return nil }
        return PromptVitals(hp: hp, mana: mana, moves: moves)
    }

    /// Compiled once — this parser runs on every displayed line while
    /// speech is on. NSRegularExpression is immutable + thread-safe.
    private static let vitalMatchers: [[NSRegularExpression]] = {
        func compile(_ units: [String]) -> [NSRegularExpression] {
            units.compactMap {
                try? NSRegularExpression(
                    pattern: #"(\d+)(?:/\d+)?\s?"# + $0 + #"\b"#,
                    options: [.caseInsensitive]
                )
            }
        }
        return [compile(["hp"]), compile(["mn", "mana", "ma"]), compile(["mv", "mov", "moves"])]
    }()

    /// The *current* value before a vitals unit: `1180hp`, `1180/1180hp`,
    /// `1180 hp` all yield 1180. First matcher wins; nil when absent.
    private static func vitalValue(in text: String, matcherIndex: Int) -> Int? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        for regex in vitalMatchers[matcherIndex] {
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            return Int((text as NSString).substring(with: match.range(at: 1)))
        }
        return nil
    }
}

/// The TTS configuration (#9), stored hand-editably in
/// `Settings/speech.json` (the soundpack.json pattern: defaults in code,
/// tolerant decode, global across worlds).
public struct SpeechConfig: SettingsFileBacked, Equatable {
    /// What gets spoken. Off by default — TTS is an accessibility opt-in.
    public var mode: SpeechMode = .off
    /// Speaking rate in words per minute. 175 ≈ the synthesizer default;
    /// experienced screen-reader users run 300–500.
    public var wordsPerMinute = 175
    /// Voice identifier or name fragment (`nil` = the system default voice).
    public var voice: String?
    /// Route through VoiceOver announcements instead of the app voice —
    /// speaks *and* brailles via the user's assistive settings (rate/voice
    /// are then owned by VoiceOver, not us).
    public var voiceOverRouting = false
    /// Prompt lines: silent by default (community canon — query vitals on
    /// demand instead); `delta` speaks only the changed hp/mana.
    public var promptSpeech: PromptSpeechMode = .off
    /// Quiet while speedwalking (the package's `tts running`).
    public var quietWhileRunning = false
    /// Sending a command cuts stale speech (`tts enter` toggles).
    public var enterInterrupts = true
    /// Quiet while Proteles isn't the active app (the package's `tts focus`).
    public var quietWhenUnfocused = false
    /// Pronunciation fixes + `!skip` speech-gags (`tts subst`).
    public var substitutions: [SpeechSubstitution] = []
    /// Speech-muted channels (`tts mute <channel>`), lowercased.
    public var mutedChannels: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(SpeechMode.self, forKey: .mode) ?? .off
        wordsPerMinute = try container.decodeIfPresent(Int.self, forKey: .wordsPerMinute) ?? 175
        voice = try container.decodeIfPresent(String.self, forKey: .voice)
        voiceOverRouting = try container.decodeIfPresent(Bool.self, forKey: .voiceOverRouting) ?? false
        promptSpeech = try container.decodeIfPresent(
            PromptSpeechMode.self, forKey: .promptSpeech
        ) ?? .off
        quietWhileRunning = try container.decodeIfPresent(Bool.self, forKey: .quietWhileRunning) ?? false
        enterInterrupts = try container.decodeIfPresent(Bool.self, forKey: .enterInterrupts) ?? true
        quietWhenUnfocused = try container.decodeIfPresent(Bool.self, forKey: .quietWhenUnfocused) ?? false
        substitutions = try container.decodeIfPresent(
            [SpeechSubstitution].self, forKey: .substitutions
        ) ?? []
        mutedChannels = try container.decodeIfPresent([String].self, forKey: .mutedChannels) ?? []
    }

    /// The session-relevant slice of this config (the rest — rate, voice,
    /// routing, focus quieting — is the app controller's).
    public var policy: SpeechPolicy {
        SpeechPolicy(
            mode: mode,
            promptSpeech: promptSpeech,
            quietWhileRunning: quietWhileRunning,
            enterInterrupts: enterInterrupts,
            substitutions: substitutions,
            mutedChannels: Set(mutedChannels.map { $0.lowercased() })
        )
    }

    /// Disk load/save via SettingsFileBacked (`Settings/speech.json`).
    public static let settingsFileName = "speech.json"
}
