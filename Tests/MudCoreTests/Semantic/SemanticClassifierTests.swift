import Foundation
@testable import MudCore
import Testing

/// The single classification point (GitHub #82).
///
/// Every line asserted here is **verbatim from a local session recording**, not
/// hand-written — `docs/AARDWOLF_DATA_FEEDS.md` §8 makes that the policy,
/// because a hand-written line encodes the author's assumption about a format
/// the player can reconfigure. Provenance is noted per case.
@Suite("SemanticClassifier — displayed lines")
struct SemanticClassifierLineTests {
    /// `session-20260821-131406.log`. The plainest case: one line, one event,
    /// categorised as progression rather than left uncategorised.
    @Test("A real level-up line classifies as progression")
    func levelUp() {
        let events = SemanticClassifier.events(
            forDisplayedText: "You raise a level! You are now level 100."
        )
        #expect(events.count == 1)
        #expect(events.first?.name == "level_up")
        #expect(events.first?.category == .progression)
    }

    /// `session-20260819-084313.log`. Guards the reference's `keep_evaluating="n"`
    /// ordering: the sequence-99 trio preempts the generic `^INFO: .+$` rule, so
    /// this must fire `double_end` **and not** `info`. Getting this wrong is
    /// silent — you would simply hear the wrong cue — so it is worth pinning.
    @Test("The sequence-99 trio preempts the generic INFO rule")
    func stopEvaluatingIsHonoured() {
        let events = SemanticClassifier.events(
            forDisplayedText: "INFO: Bonus experience has now expired."
        )
        #expect(events.map(\.name) == ["double_end"])
        #expect(events.first?.category == .progression)
    }

    /// `session-20260819-084313.log`. The same prefix that is preempted above
    /// falls through to `info` when nothing more specific claims it.
    @Test("An ordinary INFO line falls through to the generic rule")
    func genericInfoStillFires() {
        let events = SemanticClassifier.events(
            forDisplayedText: "INFO: 1 minute of bonus experience remaining."
        )
        #expect(events.map(\.name) == ["info"])
        #expect(events.first?.category == .system)
    }

    /// `session-20260819-084313.log`.
    @Test("A real double-experience announcement classifies as progression")
    func doubleExperience() {
        let events = SemanticClassifier.events(
            forDisplayedText: "Double experience for 10 minutes courtesy of Keitarou's daily blessing."
        )
        #expect(events.map(\.name) == ["double_exp"])
        #expect(events.first?.category == .progression)
    }

    /// `session-20260821-131406.log`. A mob following you — the `group`
    /// category, and a reminder that these events are not all player-initiated.
    @Test("A real follow line classifies as group")
    func follow() {
        let events = SemanticClassifier.events(
            forDisplayedText: "A warty troll starts to follow you."
        )
        #expect(events.map(\.name) == ["follow"])
        #expect(events.first?.category == .group)
    }

    /// `session-20260819-084313.log`. Most output is not an event, and the
    /// classifier must stay quiet rather than reach for a category.
    @Test("Ordinary output produces no events")
    func ordinaryOutputIsSilent() {
        for text in [
            "LOTTERY : Current lottery jackpot is at 162,385,000 gold.",
            "You stand on the edge of the beautiful City of Aylor.",
            "[ Exits: south ]",
            ""
        ] {
            #expect(SemanticClassifier.events(forDisplayedText: text).isEmpty, "\(text)")
        }
    }

    /// Line-derived events are the weakest tier and must say so, naming the rule
    /// that produced them — see `docs/AARDWOLF_DATA_FEEDS.md` §1.
    @Test("Line-derived events are marked as pattern-sourced")
    func lineEventsArePatternSourced() {
        let event = SemanticClassifier.events(
            forDisplayedText: "You raise a level! You are now level 100."
        ).first
        #expect(event?.source == .pattern(rule: "level_up"))
        #expect(event?.source.durability == 2)
    }

    /// The `Line` entry point must agree with the text one — they are the same
    /// classification, and a divergence would mean styled runs changed meaning.
    @Test("The Line and text entry points agree")
    func entryPointsAgree() {
        let text = "You raise a level! You are now level 100."
        let line = Line(id: LineID(1), timestamp: Date(timeIntervalSince1970: 0), text: text)
        #expect(
            SemanticClassifier.events(forDisplayed: line)
                == SemanticClassifier.events(forDisplayedText: text)
        )
    }
}

@Suite("SemanticClassifier — GMCP")
struct SemanticClassifierGMCPTests {
    /// GMCP is the durable tier: a channel message is the same event whatever
    /// the player's display settings, so it must be marked `.gmcp` and outrank
    /// anything pattern-derived.
    @Test("A channel message classifies from GMCP, not text")
    func channelFromGMCP() {
        let json = #"{"chan":"gossip","msg":"hi","player":"Someone"}"#
        let events = SemanticClassifier.events(forGMCP: "comm.channel", json: json)
        #expect(events.map(\.name) == ["gossip"])
        #expect(events.first?.category == .communication)
        #expect(events.first?.source == .gmcp(package: "comm.channel"))
        #expect(events.first?.source.durability == 0)
        #expect(events.first?.payload["channel"] == "gossip")
        #expect(events.first?.payload["player"] == "Someone")
    }

    /// A Chat Echo-muted speaker stays silent (#55) — the reference returns
    /// early for them, and the caller answers the mute because it is session
    /// state and this type is pure.
    @Test("A muted speaker produces no event")
    func mutedSpeakerIsSilent() {
        let json = #"{"chan":"gossip","msg":"hi","player":"Someone"}"#
        let events = SemanticClassifier.events(
            forGMCP: "comm.channel", json: json, speakerMuted: true
        )
        #expect(events.isEmpty)
    }

    /// An unknown channel fires nothing rather than being invented into the
    /// vocabulary — the reference keys its event table on the channel name.
    @Test("An unknown channel fires nothing")
    func unknownChannelIsSilent() {
        let json = #"{"chan":"not_a_channel","msg":"hi","player":"X"}"#
        #expect(SemanticClassifier.events(forGMCP: "comm.channel", json: json).isEmpty)
    }

    @Test("Quest actions map to their reference events")
    func questActions() {
        let expected = [
            "ready": "quest_ready", "killed": "quest_target_killed",
            "comp": "quest_complete", "start": "quest_start", "warning": "quest_warning"
        ]
        for (action, name) in expected {
            let events = SemanticClassifier.events(
                forGMCP: "comm.quest", json: #"{"action":"\#(action)"}"#
            )
            #expect(events.map(\.name) == [name], "\(action)")
            #expect(events.first?.source == .gmcp(package: "comm.quest"))
        }
        // "killed" is a kill, so it is combat rather than a quest update.
        let killed = SemanticClassifier.events(
            forGMCP: "comm.quest", json: #"{"action":"killed"}"#
        )
        #expect(killed.first?.category == .combat)
    }

    @Test("A repop classifies as a world event from GMCP")
    func repop() {
        let events = SemanticClassifier.events(forGMCP: "comm.repop", json: "{}")
        #expect(events.map(\.name) == ["zone_repop"])
        #expect(events.first?.category == .world)
        #expect(events.first?.source == .gmcp(package: "comm.repop"))
    }

    @Test("Unhandled packages and malformed payloads produce nothing")
    func unhandledPackages() {
        #expect(SemanticClassifier.events(forGMCP: "char.vitals", json: "{}").isEmpty)
        #expect(SemanticClassifier.events(forGMCP: "comm.channel", json: "not json").isEmpty)
        #expect(SemanticClassifier.events(forGMCP: "comm.quest", json: "{}").isEmpty)
    }
}
