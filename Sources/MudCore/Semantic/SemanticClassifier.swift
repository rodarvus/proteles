import Foundation

/// The single classification point (GitHub #82, D-118).
///
/// Turns one **displayed** line into the ``SemanticEvent``s it represents. Pure
/// — no playback, no config, no session state — so it is testable against
/// recorded transcripts without a running world.
///
/// ## Why "displayed" is load-bearing
///
/// Proteles classified the same text at two different points in the pipeline.
/// `Soundpack` fired from `ScriptEngine.process(line)`, which runs on the **raw**
/// line before any gag decision; `notifyForOutput` and `speakForOutput` run in
/// `finishDisplayedLine`, on what the player actually saw. So a line gagged by a
/// trigger, by Search-and-Destroy, or by tag cleaning still played a sound while
/// being invisible and unspoken — the asymmetry D-118 recorded.
///
/// Classifying here, once, on the displayed line, means every consumer agrees
/// about what happened. **This is a deliberate behaviour change**: sounds no
/// longer fire for gagged lines. That is the intended fix, and it is the part of
/// S0a that needs live verification rather than only a green test.
///
/// ## Source tiering
///
/// Events carry where they came from (``SemanticEvent/Source``). Line patterns
/// are the weakest tier — `docs/AARDWOLF_DATA_FEEDS.md` documents how much of
/// Aardwolf's prose is player-configurable — so pattern-derived events name the
/// rule that produced them, and anything obtainable from GMCP or a tag should be
/// classified from *that* instead of from text.
public enum SemanticClassifier {
    /// Every event a displayed line represents, in reference-trigger order.
    ///
    /// The built-in vocabulary is ``SoundEventClassifier`` — the transcription
    /// of `aard_soundpack.xml` — which decides *which named event* a line fires.
    /// This adds the category and provenance around it, so consumers other than
    /// the cue player can reason about the result.
    public static func events(forDisplayed line: Line) -> [SemanticEvent] {
        events(forDisplayedText: line.text)
    }

    /// Text-only entry point, for transcript replay where only the text of a
    /// recorded line survives.
    public static func events(forDisplayedText text: String) -> [SemanticEvent] {
        SoundEventClassifier.events(forLine: text).map { name in
            SemanticEvent(
                category: SemanticEventVocabulary.category(for: name) ?? .system,
                name: name,
                source: .pattern(rule: name)
            )
        }
    }

    /// The events a GMCP package represents.
    ///
    /// Structural rather than textual, so these are the durable half: a channel
    /// message, a quest transition or a repop is the same event regardless of
    /// how the player has configured their display.
    ///
    /// `speakerMuted` mirrors the reference's behaviour of staying silent for a
    /// Chat Echo-muted speaker (#55) — the caller answers it, because muting is
    /// session state and this type is pure.
    public static func events(
        forGMCP package: String,
        json: String,
        speakerMuted: Bool = false
    ) -> [SemanticEvent] {
        switch package.lowercased() {
        case "comm.channel":
            guard !speakerMuted,
                  let comm = try? JSONDecoder().decode(CommChannel.self, from: Data(json.utf8)),
                  let name = SoundEventClassifier.channelEvent(chan: comm.chan)
            else { return [] }
            return [
                SemanticEvent(
                    category: SemanticEventVocabulary.category(for: name) ?? .communication,
                    name: name,
                    source: .gmcp(package: "comm.channel"),
                    payload: payload(for: comm)
                )
            ]

        case "comm.quest":
            guard let data = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
                  let action = (data as? [String: Any])?["action"] as? String,
                  let name = SoundEventClassifier.questEvent(action: action)
            else { return [] }
            return [
                SemanticEvent(
                    category: SemanticEventVocabulary.category(for: name) ?? .world,
                    name: name,
                    source: .gmcp(package: "comm.quest"),
                    payload: ["action": action]
                )
            ]

        case "comm.repop":
            let name = SoundEventClassifier.zoneRepopEvent
            return [
                SemanticEvent(
                    category: SemanticEventVocabulary.category(for: name) ?? .world,
                    name: name,
                    source: .gmcp(package: "comm.repop")
                )
            ]

        default:
            return []
        }
    }

    /// Channel payload a consumer might key on — the channel and who spoke.
    /// Kept minimal: these two have readers (cue selection, notification rules);
    /// the rest of the packet does not.
    private static func payload(for comm: CommChannel) -> [String: String] {
        var payload = ["channel": comm.chan]
        if !comm.player.isEmpty { payload["player"] = comm.player }
        return payload
    }
}
