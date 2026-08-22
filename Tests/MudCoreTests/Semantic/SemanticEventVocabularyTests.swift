import Foundation
@testable import MudCore
import Testing

/// The S0a taxonomy (GitHub #82). These tests exist to keep two things honest:
/// that the built-in vocabulary stays *total* over the reference soundpack, and
/// that the GMCP > tags > patterns ordering rule from
/// `docs/AARDWOLF_DATA_FEEDS.md` is a property of the model rather than a
/// convention people remember.
@Suite("SemanticEvent — taxonomy")
struct SemanticEventVocabularyTests {
    /// The load-bearing one. `SoundEventClassifier` is a transcription of
    /// somebody else's plugin, so it grows when the reference grows. If an event
    /// is added there and not categorised here, consumers that key on category
    /// would silently drop it — this fails the gates instead.
    @Test("Every soundpack event has a category")
    func vocabularyIsTotal() {
        let uncategorised = SoundEventClassifier.defaults.keys
            .filter { SemanticEventVocabulary.category(for: $0) == nil }
            .sorted()
        #expect(
            uncategorised.isEmpty,
            "soundpack events with no SemanticEvent category: \(uncategorised)"
        )
    }

    /// The reverse direction: a category entry naming an event the reference
    /// does not fire is dead weight, and usually a typo.
    @Test("No category entry names an unknown event")
    func vocabularyHasNoStrays() {
        let strays = SemanticEventVocabulary.categories.keys
            .filter { SoundEventClassifier.defaults[$0] == nil }
            .sorted()
        #expect(strays.isEmpty, "categorised events the soundpack never fires: \(strays)")
    }

    /// Each event belongs to exactly one grouping — the sets must not overlap,
    /// or `categories` would resolve by construction order rather than by intent.
    @Test("The groupings are disjoint")
    func groupingsAreDisjoint() {
        let groups: [(String, Set<String>)] = [
            ("communication", SemanticEventVocabulary.communication),
            ("world", SemanticEventVocabulary.world),
            ("combat", SemanticEventVocabulary.combat),
            ("progression", SemanticEventVocabulary.progression),
            ("inventory", SemanticEventVocabulary.inventory),
            ("group", SemanticEventVocabulary.group),
            ("system", SemanticEventVocabulary.system)
        ]
        for (indexA, (nameA, setA)) in groups.enumerated() {
            for (nameB, setB) in groups.dropFirst(indexA + 1) {
                let overlap = setA.intersection(setB).sorted()
                #expect(overlap.isEmpty, "\(nameA) and \(nameB) both claim \(overlap)")
            }
        }
    }

    /// Spot-checks anchored to the reference's own descriptions, so a future
    /// re-shuffle has to justify itself against what Aardwolf says the event is.
    @Test("Categories follow the reference descriptions")
    func categoriesMatchReferenceMeaning() {
        // "Comm Chan: Tell" / "Comm Chan: Gossip" — a person said something.
        #expect(SemanticEventVocabulary.category(for: "tell") == .communication)
        #expect(SemanticEventVocabulary.category(for: "gossip") == .communication)
        // "Quest target killed" / "CP target killed" — a kill, not a quest update.
        #expect(SemanticEventVocabulary.category(for: "quest_target_killed") == .combat)
        #expect(SemanticEventVocabulary.category(for: "cp_mob_dead") == .combat)
        // "Quest is available" — the world offering something.
        #expect(SemanticEventVocabulary.category(for: "quest_ready") == .world)
        #expect(SemanticEventVocabulary.category(for: "zone_repop") == .world)
        // "Level up" / "Double experience started".
        #expect(SemanticEventVocabulary.category(for: "level_up") == .progression)
        #expect(SemanticEventVocabulary.category(for: "double_exp") == .progression)
        // "Looted a bonus item with enhanced stats" — an item arrived.
        #expect(SemanticEventVocabulary.category(for: "bonus_item") == .inventory)
        // "Info messages" — a server broadcast, not a person.
        #expect(SemanticEventVocabulary.category(for: "info") == .system)
        // "Sound when you follow a player".
        #expect(SemanticEventVocabulary.category(for: "follow") == .group)
    }

    /// A name outside the built-in pack (plugin- or user-raised) resolves to
    /// nothing rather than being forced into a category.
    @Test("Unknown events are not guessed at")
    func unknownEventsReturnNil() {
        #expect(SemanticEventVocabulary.category(for: "not_a_real_event") == nil)
        #expect(SemanticEventVocabulary.category(for: "") == nil)
    }
}

@Suite("SemanticEvent — source durability")
struct SemanticEventSourceTests {
    /// The feeds doc's ordering rule (GMCP > tags > line patterns) expressed as
    /// a property. A consumer choosing between two events describing the same
    /// moment should be able to prefer the structural one, and this is what
    /// makes that possible without every call site re-deciding.
    @Test("Durability ranks GMCP above tags above patterns")
    func durabilityOrdering() {
        let gmcp = SemanticEvent.Source.gmcp(package: "char.status")
        let tag = SemanticEvent.Source.tag(family: "roomchars")
        let pattern = SemanticEvent.Source.pattern(rule: "level_up")
        #expect(gmcp.durability < tag.durability)
        #expect(tag.durability < pattern.durability)
    }

    /// The source carries *which* feed, not merely which tier — a failing event
    /// should be traceable to the package, tag family or rule that produced it.
    @Test("Source identifies its specific feed")
    func sourceIdentifiesFeed() {
        let event = SemanticEvent(
            category: .combat,
            name: "death",
            source: .pattern(rule: "own_death"),
            payload: ["killer": "a mosquito"]
        )
        #expect(event.source == .pattern(rule: "own_death"))
        #expect(event.payload["killer"] == "a mosquito")
        #expect(event.source.durability == 2)
    }
}
