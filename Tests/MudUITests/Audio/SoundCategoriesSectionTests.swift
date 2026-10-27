import Foundation
import MudCore
@testable import MudUI
import Testing

/// Settings ▸ Audio's category rows (S1 step 6, #83): each category's events,
/// what each one's ▶ plays, and why it is disabled when it is
/// (`docs/plans/S1_ITEM6_PROPOSAL.md`).
@Suite("Settings ▸ Audio — sound categories")
struct SoundCategoriesSectionTests {
    @Test("a category lists its events, each previewing its cue at the effective volume")
    func rowsPreviewTheirCue() throws {
        var config = SoundpackConfig()
        config.setVolume(40, for: .world)
        let rows = SoundEventPreview.rows(in: .world, config: config)
        #expect(rows.map(\.event) == SemanticEventVocabulary.events(in: .world))
        let ready = try #require(rows.first { $0.event == "quest_ready" })
        #expect(ready.cue == SoundCue(
            file: "quest_ready.wav",
            volume: SoundVolume.linearGain(forPercent: 40),
            pan: 0,
            event: "quest_ready"
        ))
        #expect(ready.detail.contains("quest_ready.wav"))
    }

    @Test("a category at 0 previews nothing, and says why")
    func zeroCapSilences() {
        var config = SoundpackConfig()
        config.setVolume(0, for: .combat)
        let rows = SoundEventPreview.rows(in: .combat, config: config)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.cue == nil && $0.silentReason.hasPrefix("Volume is 0") })
    }

    @Test("an event with no file previews nothing and points at spset")
    func noFileSaysSo() throws {
        let rows = SoundEventPreview.rows(in: .affect, config: SoundpackConfig())
        let affectOn = try #require(rows.first { $0.event == "affect_on" })
        #expect(affectOn.cue == nil)
        #expect(affectOn.detail == "no sound set")
        #expect(affectOn.silentReason.contains("spset affect_on wav"))
    }

    @Test("a sound set with spset previews; the window doesn't need a default")
    func overridePreviews() {
        var config = SoundpackConfig()
        config.updateOverride(for: "affect_on") { $0.files = ["spell_on.wav"] }
        let row = SoundEventPreview.rows(in: .affect, config: config).first { $0.event == "affect_on" }
        #expect(row?.cue?.file == "spell_on.wav")
    }

    @Test("every category has a title; only triggers and notifications point elsewhere")
    func categoryText() {
        for category in SemanticEvent.Category.allCases {
            #expect(!SoundCategoryText.title(for: category).isEmpty)
        }
        let elsewhere = SemanticEvent.Category.allCases.filter { SoundCategoryText.note(for: $0) != nil }
        #expect(Set(elsewhere) == [.custom, .notification])
    }
}
