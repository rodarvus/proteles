import Foundation

/// The built-in Aardwolf event vocabulary: every event name the shipped
/// soundpack fires, assigned to a ``SemanticEvent/Category`` (GitHub #82).
///
/// This is the "demote the classifier to a vocabulary pack" half of D-118.
/// ``SoundEventClassifier`` stays the transcription of `aard_soundpack.xml` —
/// which patterns fire which *named* event — and this table says what each of
/// those names *is*, so consumers other than the cue player can reason about
/// them. Sound continues to key on the name; muting, subscription and (later)
/// lens surfaces key on the category.
///
/// **Totality is enforced by test**, not by care: `SemanticEventVocabularyTests`
/// fails if any soundpack event is missing here, so adding an event to the
/// classifier without categorising it cannot pass the gates. That matters
/// because the vocabulary is a transcription of somebody else's plugin — it
/// grows when the reference grows, not when we decide it should.
public enum SemanticEventVocabulary {
    /// Event name → category, covering the full reference vocabulary.
    ///
    /// Categorisation follows the reference's own descriptions rather than
    /// intuition: the 37 events described `Comm Chan: …` are unambiguously
    /// ``SemanticEvent/Category/communication``, and the rest follow their
    /// stated meaning (`Quest target killed` → combat, `Zone repops` → world).
    public static let categories: [String: SemanticEvent.Category] = {
        var table: [String: SemanticEvent.Category] = [:]
        for name in communication {
            table[name] = .communication
        }
        for name in world {
            table[name] = .world
        }
        for name in combat {
            table[name] = .combat
        }
        for name in progression {
            table[name] = .progression
        }
        for name in inventory {
            table[name] = .inventory
        }
        for name in group {
            table[name] = .group
        }
        for name in system {
            table[name] = .system
        }
        return table
    }()

    /// The category for a soundpack event name, or `nil` if it is not part of
    /// the built-in vocabulary (a plugin-raised or user-defined name).
    public static func category(for event: String) -> SemanticEvent.Category? {
        categories[event]
    }

    // MARK: - The groupings

    /// Channels, tells, says and socials — anything another *person* sent.
    /// Includes the channel on/off toggles (they are about the comms surface)
    /// and `remote_sound` (a remote social another player triggered).
    static let communication: Set<String> = [
        "answer", "auction", "barter", "claninfo", "clantalk", "curse", "debate",
        "epics", "ftalk", "gametalk", "gclan", "gossip", "gratz", "gsocial",
        "gtell", "helper", "immtalk", "inform", "ltalk", "market", "music",
        "newbie", "nobletalk", "pokerinfo", "question", "quote", "racetalk",
        "rauction", "rp", "say", "spouse", "tech", "tell", "tiertalk", "wangrp",
        "whisper", "yell",
        "channel_on", "channel_off",
        "remote_sound",
        // A note is mail from a person, not a server broadcast.
        "personal_note"
    ]

    /// Quests, campaigns, global quests, repops, warfare — the world moving
    /// around the player. `aarch_prof` is the Aarchaeology professor appearing
    /// in the room: a world occurrence, not a message.
    static let world: Set<String> = [
        "zone_repop", "warfare", "aarch_prof",
        "quest_ready", "quest_start", "quest_complete", "quest_warning",
        "quest_target_found",
        "gquest_declare", "gquest_start", "gq_win"
    ]

    /// Kills and deaths. Small on purpose — the decomposition found combat is
    /// the *only* genuinely event-shaped entity, but the shipped vocabulary
    /// barely covers it. Combat-round events come from the S0a classifier work,
    /// not from the soundpack transcription.
    static let combat: Set<String> = [
        "death", "cp_mob_dead", "gq_mob_dead", "quest_target_killed"
    ]

    /// Levels, superhero milestones, and the double-experience window.
    static let progression: Set<String> = [
        "level_up", "sh_powerup", "reach_sh", "double_exp", "double_end"
    ]

    /// Items acquired. Updates S0b's item entities.
    static let inventory: Set<String> = [
        "special_find", "bonus_item"
    ]

    /// Grouping and following.
    static let group: Set<String> = [
        "follow", "stop_follow"
    ]

    /// Server broadcasts addressed to everyone, or to the player by the game
    /// rather than by a person.
    static let system: Set<String> = [
        "info", "restore", "manor_doorbell", "scry"
    ]
}
