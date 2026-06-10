import Foundation

/// The Aardwolf soundpack's event vocabulary, transcribed from the reference
/// plugin (`aard_soundpack.xml`, Pwar's `Aardwolf_Soundpack` 1.1.2) — issue
/// #10. Pure data + matching, no playback: the ``Soundpack`` native plugin
/// consumes this to decide *which* event a line/GMCP message fires, and maps
/// the event to a cue file via its config.
///
/// Three sources fire events, exactly as in the reference:
/// - **48 line triggers** (level-up, death, scry, doorbell, double-exp, …) —
///   ``events(forLine:)``.
/// - **`comm.channel` GMCP** — the channel name *is* the event key
///   (``channelEvent(chan:)``).
/// - **`comm.quest` GMCP** — `action` maps to five quest events
///   (``questEvent(action:)``); `comm.repop` fires ``zoneRepopEvent``.
public enum SoundEventClassifier {
    /// An event's reference defaults: its wav filename and the human
    /// description `spset` lists. (Default volume is 100, pan 0, for every
    /// event — only deviations are stored in the user's config.)
    public struct EventDefault: Sendable, Equatable {
        public let file: String
        public let description: String
    }

    /// One transcribed reference trigger: PCRE pattern → event.
    struct Rule {
        let pattern: String
        let event: String
        /// `keep_evaluating="n"` in the reference (the sequence-99 trio) —
        /// a match stops evaluation so `^INFO: .+$` doesn't also fire.
        var stopsEvaluation = false
        /// The `Crumble` trigger's guard: capture `goldCaptureIndex` (commas
        /// stripped) must be ≥ 100,000 for the event to fire.
        var goldCaptureIndex: Int?
    }

    /// `comm.repop` → this event.
    public static let zoneRepopEvent = "zone_repop"

    /// `comm.quest` `action` → event (reference `OnPluginBroadcast`).
    public static func questEvent(action: String) -> String? {
        switch action {
        case "ready": "quest_ready"
        case "killed": "quest_target_killed"
        case "comp": "quest_complete"
        case "start": "quest_start"
        case "warning": "quest_warning"
        default: nil
        }
    }

    /// `comm.channel` → event: the channel name keys the event table
    /// directly (`soundEvents[channel]` in the reference); unknown channels
    /// fire nothing.
    public static func channelEvent(chan: String) -> String? {
        defaults[chan] != nil ? chan : nil
    }

    /// Every event a line fires, in reference trigger order. The sequence-99
    /// trio (`keep_evaluating="n"`) preempts later rules — so `INFO: Bonus
    /// experience has now expired.` fires `double_end`, not `info`.
    public static func events(forLine text: String) -> [String] {
        var events: [String] = []
        for (index, rule) in rules.enumerated() {
            guard let matcher = compiledRules[index], let match = matcher.match(text) else { continue }
            if let goldIndex = rule.goldCaptureIndex {
                // Crumble: only worth a sound at 100k gold and higher.
                let raw = match.captures.count > goldIndex ? match.captures[goldIndex] : ""
                let amount = Int(raw.replacingOccurrences(of: ",", with: "")) ?? 0
                guard amount >= 100_000 else { continue }
            }
            if !events.contains(rule.event) { events.append(rule.event) }
            if rule.stopsEvaluation { break }
        }
        return events
    }

    /// The 48 reference triggers, in document order (sequence 99 trio first,
    /// matching MUSHclient's sequence-then-match-text evaluation order).
    /// Patterns are verbatim from `aard_soundpack.xml`.
    static let rules: [Rule] = [
        Rule(
            pattern: #"^INFO: Bonus experience has now expired.$"#,
            event: "double_end",
            stopsEvaluation: true
        ),
        Rule(
            pattern: #"^INFO: New post (.+) in forum Personal from (.+)$"#,
            event: "personal_note",
            stopsEvaluation: true
        ),
        Rule(
            pattern: #"^You were the first to complete this quest!$"#,
            event: "gq_win",
            stopsEvaluation: true
        ),
        Rule(pattern: #"^INFO: .+$"#, event: "info"),
        Rule(
            pattern: #"^For the next 15 minutes experience is doubled in honor of the new superhero.$"#,
            event: "double_exp"
        ),
        Rule(pattern: #"^\[(.+)10 minutes of double exp started courtesy of (.+)\]$"#, event: "double_exp"),
        Rule(
            pattern: #"^Double experience for 10 minutes courtesy of (.+) daily blessing.$"#,
            event: "double_exp"
        ),
        Rule(pattern: #"^Double experience for 10 minutes courtesy of (.+).$"#, event: "double_exp"),
        Rule(pattern: #"^Aardwolf rejoices in the death of another MILLION monsters.$"#, event: "double_exp"),
        Rule(pattern: #"^WARFARE: Type \'combat\' to join the war. No death penalties!$"#, event: "warfare"),
        Rule(pattern: #"^Restore: .+$"#, event: "restore"),
        Rule(pattern: #"^Remort Auction: .+$"#, event: "rauction"),
        Rule(pattern: #"^.+\[QUEST\]$"#, event: "quest_target_found"),
        Rule(
            pattern: #"(.+)?Andolor's very own \(Aarchaeology\) Professor is here, studying\.$"#,
            event: "aarch_prof"
        ),
        Rule(pattern: #"^QUEST: You have run out of time for your quest!$"#, event: "quest_warning"),
        Rule(pattern: #"^You feel as if you are being watched.$"#, event: "scry"),
        Rule(pattern: #"^You sense that (.+) is scrying you.$"#, event: "scry"),
        Rule(pattern: #"^\*\* You can take revenge on (.+) for 15 minutes.$"#, event: "scry"),
        Rule(pattern: #"^You raise a level! You are now level (.+)\.$"#, event: "level_up"),
        Rule(
            pattern: #"^Congratulations, \w+\. You have increased your powerups to \d+\.$"#,
            event: "sh_powerup"
        ),
        Rule(pattern: #"^You die.$"#, event: "death"),
        Rule(pattern: #"^Congratulations! You are now a superhero!(.+)$"#, event: "reach_sh"),
        Rule(
            pattern: #"^You ring the bell and hope that someone inside hears you\.$"#,
            event: "manor_doorbell"
        ),
        Rule(pattern: #"^(.+) is outside ringing the bell!$"#, event: "manor_doorbell"),
        Rule(pattern: #"^You start to follow (.+)\.$"#, event: "follow"),
        Rule(pattern: #"^You stop following (.+)\.$"#, event: "stop_follow"),
        Rule(pattern: #"^(.+) starts to follow you\.$"#, event: "follow"),
        Rule(pattern: #"^(.+) stops following you\.$"#, event: "stop_follow"),
        Rule(pattern: #"^(.+) has invited you to join group: (.+)\.$"#, event: "gtell"),
        Rule(pattern: #"^You have removed yourself from group: (.+)$"#, event: "gtell"),
        Rule(pattern: #"^(.+) has kicked you from the group\.$"#, event: "gtell"),
        Rule(pattern: #"\[CP\]$"#, event: "quest_target_found"),
        Rule(pattern: #"^Turning OFF the (.+) channel\.$"#, event: "channel_off"),
        Rule(pattern: #"^Channel (.+) will turn back on in (.*).$"#, event: "channel_off"),
        Rule(pattern: #"^Turning ON the (.+) channel\.$"#, event: "channel_on"),
        Rule(pattern: #"^Removing timeout and turning ON the (.*) channel.$"#, event: "channel_on"),
        Rule(pattern: #"^You find an \(Aarchaeology\) piece hidden in the corpse!$"#, event: "special_find"),
        Rule(
            pattern: #"^You find a \|P\[Poker Card\]P\| special item hidden in the corpse!$"#,
            event: "special_find"
        ),
        Rule(
            pattern: #"^You get AardWords \(TM\) - (.+) from the (.+) corpse of (.+).$"#,
            event: "special_find"
        ),
        Rule(pattern: #"^\*\* You gain a bonus trivia point! \*\*$"#, event: "special_find"),
        Rule(
            pattern: #"^You killed a Trivia Point bonus mob\!\! Trivia point added\.$"#,
            event: "special_find"
        ),
        Rule(pattern: #"^You get \((.+)\) (.+) from (.+) corpse of (.+)\.$"#, event: "bonus_item"),
        Rule(
            pattern: #"^(.+) crumbles into (.*) gold pieces\.$"#,
            event: "special_find",
            goldCaptureIndex: 2
        ),
        Rule(pattern: #"^Channel timeout on (.*) has expired. Turning channel on.$"#, event: "channel_on"),
        Rule(pattern: #"^Congratulations\, that was one of your CAMPAIGN mobs\!$"#, event: "cp_mob_dead"),
        Rule(pattern: #"^Congratulations\, that was one of the GLOBAL QUEST mobs\!$"#, event: "gq_mob_dead"),
        Rule(pattern: #"^Global Quest: Global quest # (.*) has been declared(.*)$"#, event: "gquest_declare"),
        Rule(
            pattern: #"^Global Quest: Global quest # (.*) for levels (.*) has now started.$"#,
            event: "gquest_start"
        )
    ]

    /// Compiled rule matchers, index-aligned with ``rules``. A pattern that
    /// fails to compile yields `nil` (tests assert all 48 compile).
    static let compiledRules: [PatternMatcher?] = rules.map {
        try? PatternMatcher(pattern: .regex($0.pattern), caseSensitive: true)
    }

    /// Event names sorted for listing (`spset` shows them alphabetically,
    /// like the reference's `orderedPairs`).
    public static let orderedEventNames: [String] = defaults.keys.sorted()

    /// The 69-event default table from the reference (`soundEvents`): event →
    /// default wav + description. Volume 100 / pan 0 everywhere.
    public static let defaults: [String: EventDefault] = [
        "zone_repop": .init(file: "zone_repop.wav", description: "Zone repops (respawns)"),
        "info": .init(file: "info.wav", description: "Info messages"),
        "personal_note": .init(file: "personal_note.wav", description: "Personal note received"),
        "gq_win": .init(file: "gq_win.wav", description: "Global quest won"),
        "special_find": .init(file: "special_find.wav", description: "Aarchaelogy or AardWords item"),
        "bonus_item": .init(file: "bonus_item.wav", description: "Looted a bonus item with enhanced stats"),
        "manor_doorbell": .init(file: "manor_doorbell.wav", description: "Doorbells for ring bell at manor"),
        "follow": .init(file: "follow.wav", description: "Sound when you follow a player"),
        "stop_follow": .init(file: "stop_follow.wav", description: "Sound when you stop following a player"),
        "warfare": .init(file: "warfare.wav", description: "Warfare has been declared"),
        "restore": .init(file: "restore.wav", description: "Restore messages"),
        "gquest_start": .init(file: "global_quest.wav", description: "Gquest is started"),
        "gquest_declare": .init(file: "global_quest.wav", description: "Gquest has been declared"),
        "aarch_prof": .init(file: "aarch_prof.wav", description: "Aarch Professor in room"),
        "quest_target_found": .init(file: "quest_target_found.wav", description: "Quest target in room"),
        "quest_target_killed": .init(file: "quest_target_killed.wav", description: "Quest target killed"),
        "quest_ready": .init(file: "quest_ready.wav", description: "Quest is available"),
        "quest_start": .init(file: "quest_start.wav", description: "Quest has started"),
        "quest_complete": .init(file: "quest_complete.wav", description: "Quest completed"),
        "quest_warning": .init(file: "quest_warning.wav", description: "Quest time warnings"),
        "death": .init(file: "death.wav", description: "Your own death"),
        "cp_mob_dead": .init(file: "cp_mob_dead.wav", description: "CP target killed"),
        "double_end": .init(file: "double_end.wav", description: "Double experience ended"),
        "double_exp": .init(file: "double_exp.wav", description: "Double experience started"),
        "gq_mob_dead": .init(file: "gq_mob_dead.wav", description: "Gquest target killed"),
        "channel_off": .init(file: "channel_off.wav", description: "Channel toggle off"),
        "channel_on": .init(file: "channel_on.wav", description: "Channel toggle on"),
        "answer": .init(file: "answer.wav", description: "Comm Chan: Answer"),
        "auction": .init(file: "auction.wav", description: "Comm Chan: Auctions"),
        "rauction": .init(file: "rauction.wav", description: "Comm Chan: Remort Auctions"),
        "barter": .init(file: "barter.wav", description: "Comm Chan: Barter"),
        "claninfo": .init(file: "claninfo.wav", description: "Comm Chan: ClanInfo"),
        "clantalk": .init(file: "clantalk.wav", description: "Comm Chan: ClanTalk"),
        "curse": .init(file: "curse.wav", description: "Comm Chan: Curse"),
        "debate": .init(file: "debate.wav", description: "Comm Chan: Debate"),
        "epics": .init(file: "epic.wav", description: "Comm Chan: Epics"),
        "ftalk": .init(file: "ftalk.wav", description: "Comm Chan: Ftalk"),
        "gametalk": .init(file: "gametalk.wav", description: "Comm Chan: Gametalk"),
        "gclan": .init(file: "gclan.wav", description: "Comm Chan: Gclan"),
        "gossip": .init(file: "gossip.wav", description: "Comm Chan: Gossip"),
        "gratz": .init(file: "gratz.wav", description: "Comm Chan: Gratz"),
        "gsocial": .init(file: "gsocial.wav", description: "Comm Chan: Gsocial"),
        "gtell": .init(file: "gtell.wav", description: "Comm Chan: Gtell"),
        "helper": .init(file: "helper.wav", description: "Comm Chan: Helper"),
        "immtalk": .init(file: "immtalk.wav", description: "Comm Chan: ImmTalk"),
        "inform": .init(file: "inform.wav", description: "Comm Chan: Inform"),
        "level_up": .init(file: "level_up.wav", description: "Level up"),
        "sh_powerup": .init(file: "level_up.wav", description: "Superhero powerup"),
        "reach_sh": .init(file: "level_up_sh.wav", description: "Reach Superhero"),
        "ltalk": .init(file: "ltalk.wav", description: "Comm Chan: Ltalk"),
        "market": .init(file: "market.wav", description: "Comm Chan: Market"),
        "music": .init(file: "music.wav", description: "Comm Chan: Music"),
        "newbie": .init(file: "newbie.wav", description: "Comm Chan: Newbie"),
        "nobletalk": .init(file: "nobletalk.wav", description: "Comm Chan: NobleTalk"),
        "pokerinfo": .init(file: "pokerinfo.wav", description: "Comm Chan: PokerInfo"),
        "question": .init(file: "question.wav", description: "Comm Chan: Question"),
        "quote": .init(file: "quote.wav", description: "Comm Chan: Quote"),
        "racetalk": .init(file: "racetalk.wav", description: "Comm Chan: Racetalk"),
        "rp": .init(file: "rp.wav", description: "Comm Chan: RP"),
        "say": .init(file: "say.wav", description: "Comm Chan: Say"),
        "scry": .init(file: "scry.wav", description: "Scried by player"),
        "spouse": .init(file: "spouse.wav", description: "Comm Chan: Spouse"),
        "remote_sound": .init(file: "none.wav", description: "Remote Sounds"),
        "tech": .init(file: "tech.wav", description: "Comm Chan: Tech"),
        "tell": .init(file: "tell.wav", description: "Comm Chan: Tell"),
        "tiertalk": .init(file: "tiertalk.wav", description: "Comm Chan: TierTalk"),
        "wangrp": .init(file: "wangrp.wav", description: "Comm Chan: WanGrp"),
        "yell": .init(file: "yell.wav", description: "Comm Chan: Yell"),
        "whisper": .init(file: "whisper.wav", description: "Comm Chan: Whisper")
    ]
}
