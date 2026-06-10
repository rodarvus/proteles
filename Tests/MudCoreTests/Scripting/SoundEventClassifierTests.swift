import Foundation
@testable import MudCore
import Testing

/// The soundpack event vocabulary (#10) against exact reference lines —
/// every transcribed trigger fires its event, the sequence-99 preemptions
/// hold, the Crumble gold threshold gates, and the GMCP keying matches
/// `aard_soundpack.xml`'s `OnPluginBroadcast`.
@Suite("SoundEventClassifier — the aard_soundpack transcription")
struct SoundEventClassifierTests {
    @Test("all 48 reference patterns compile")
    func allRulesCompile() {
        #expect(SoundEventClassifier.rules.count == 48)
        for (index, compiled) in SoundEventClassifier.compiledRules.enumerated() {
            #expect(
                compiled != nil,
                "pattern failed to compile: \(SoundEventClassifier.rules[index].pattern)"
            )
        }
    }

    @Test("the 69-event default table is complete and every rule's event exists in it")
    func tableComplete() {
        #expect(SoundEventClassifier.defaults.count == 69)
        for rule in SoundEventClassifier.rules {
            #expect(
                SoundEventClassifier.defaults[rule.event] != nil,
                "rule event missing from table: \(rule.event)"
            )
        }
    }

    @Test("line triggers fire their reference events", arguments: [
        ("You raise a level! You are now level 142.", "level_up"),
        ("Congratulations, Rodarvus. You have increased your powerups to 12.", "sh_powerup"),
        ("You die.", "death"),
        ("Congratulations! You are now a superhero! Welcome to level 201.", "reach_sh"),
        ("You feel as if you are being watched.", "scry"),
        ("You sense that Eketra is scrying you.", "scry"),
        ("** You can take revenge on Throk for 15 minutes.", "scry"),
        ("You ring the bell and hope that someone inside hears you.", "manor_doorbell"),
        ("Eketra is outside ringing the bell!", "manor_doorbell"),
        ("You start to follow Eketra.", "follow"),
        ("Eketra starts to follow you.", "follow"),
        ("You stop following Eketra.", "stop_follow"),
        ("Eketra stops following you.", "stop_follow"),
        ("Eketra has invited you to join group: ascension.", "gtell"),
        ("You have removed yourself from group: ascension", "gtell"),
        ("Eketra has kicked you from the group.", "gtell"),
        ("a quivering blob of flesh [QUEST]", "quest_target_found"),
        ("a quivering blob of flesh [CP]", "quest_target_found"),
        ("QUEST: You have run out of time for your quest!", "quest_warning"),
        ("Andolor's very own (Aarchaeology) Professor is here, studying.", "aarch_prof"),
        ("WARFARE: Type 'combat' to join the war. No death penalties!", "warfare"),
        ("Restore: Lasher restores the world!", "restore"),
        ("Remort Auction: bidding on Wolf Spirit is now open.", "rauction"),
        ("For the next 15 minutes experience is doubled in honor of the new superhero.", "double_exp"),
        ("[ 10 minutes of double exp started courtesy of Lasher ]", "double_exp"),
        ("Double experience for 10 minutes courtesy of Eketra's daily blessing.", "double_exp"),
        ("Double experience for 10 minutes courtesy of Lasher.", "double_exp"),
        ("Aardwolf rejoices in the death of another MILLION monsters.", "double_exp"),
        ("You find an (Aarchaeology) piece hidden in the corpse!", "special_find"),
        ("You find a |P[Poker Card]P| special item hidden in the corpse!", "special_find"),
        ("You get AardWords (TM) - E from the bloody corpse of a goblin.", "special_find"),
        ("** You gain a bonus trivia point! **", "special_find"),
        ("You killed a Trivia Point bonus mob!! Trivia point added.", "special_find"),
        ("You get (Glowing) a fiery sword from the smoking corpse of a demon.", "bonus_item"),
        ("Turning OFF the gossip channel.", "channel_off"),
        ("Channel gossip will turn back on in 5 minutes.", "channel_off"),
        ("Turning ON the gossip channel.", "channel_on"),
        ("Removing timeout and turning ON the gossip channel.", "channel_on"),
        ("Channel timeout on gossip has expired. Turning channel on.", "channel_on"),
        ("Congratulations, that was one of your CAMPAIGN mobs!", "cp_mob_dead"),
        ("Congratulations, that was one of the GLOBAL QUEST mobs!", "gq_mob_dead"),
        ("Global Quest: Global quest # 12345 has been declared for levels 150 to 180.", "gquest_declare"),
        ("Global Quest: Global quest # 12345 for levels 150 to 180 has now started.", "gquest_start")
    ])
    func lineEvents(line: String, event: String) {
        #expect(SoundEventClassifier.events(forLine: line) == [event])
    }

    @Test("sequence-99 preemption: the specific INFO rules beat the general info rule")
    func infoPreemption() {
        #expect(SoundEventClassifier
            .events(forLine: "INFO: Bonus experience has now expired.") == ["double_end"])
        #expect(SoundEventClassifier.events(
            forLine: "INFO: New post 'hi' in forum Personal from Eketra"
        ) == ["personal_note"])
        #expect(SoundEventClassifier
            .events(forLine: "You were the first to complete this quest!") == ["gq_win"])
        // Any other INFO line falls through to the general rule.
        #expect(SoundEventClassifier.events(forLine: "INFO: Eketra has remorted.") == ["info"])
    }

    @Test("Crumble fires special_find only at 100k gold and higher (commas stripped)")
    func crumbleThreshold() {
        #expect(SoundEventClassifier.events(
            forLine: "A pile of bones crumbles into 250,000 gold pieces."
        ) == ["special_find"])
        #expect(SoundEventClassifier.events(
            forLine: "A pile of bones crumbles into 100000 gold pieces."
        ) == ["special_find"])
        #expect(SoundEventClassifier.events(
            forLine: "A pile of bones crumbles into 99,999 gold pieces."
        ).isEmpty)
    }

    @Test("ordinary prose fires nothing")
    func quietLines() {
        #expect(SoundEventClassifier.events(forLine: "The Grand City of Aylor").isEmpty)
        #expect(SoundEventClassifier.events(forLine: "You attack a giant rat!").isEmpty)
        #expect(SoundEventClassifier.events(forLine: "").isEmpty)
    }

    @Test("comm.quest actions map to the five quest events")
    func questActions() {
        #expect(SoundEventClassifier.questEvent(action: "ready") == "quest_ready")
        #expect(SoundEventClassifier.questEvent(action: "killed") == "quest_target_killed")
        #expect(SoundEventClassifier.questEvent(action: "comp") == "quest_complete")
        #expect(SoundEventClassifier.questEvent(action: "start") == "quest_start")
        #expect(SoundEventClassifier.questEvent(action: "warning") == "quest_warning")
        #expect(SoundEventClassifier.questEvent(action: "timeout") == nil)
    }

    @Test("comm.channel keys the event table directly; unknown channels are silent")
    func channelKeying() {
        #expect(SoundEventClassifier.channelEvent(chan: "tell") == "tell")
        #expect(SoundEventClassifier.channelEvent(chan: "gossip") == "gossip")
        #expect(SoundEventClassifier.channelEvent(chan: "gratz") == "gratz")
        #expect(SoundEventClassifier.channelEvent(chan: "notachannel") == nil)
        // Non-channel events in the table still key (the reference indexes
        // soundEvents[chan] without a kind check).
        #expect(SoundEventClassifier.zoneRepopEvent == "zone_repop")
    }
}
