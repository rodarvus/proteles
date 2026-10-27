import Foundation
@testable import MudCore
import Testing

/// The window and the console edit one store (S1 step 6, #83): a category cap
/// the Settings window saves is the one the soundpack plays under, and
/// `spcat` reads.
@Suite("sound categories — one store for the window and the console")
struct SoundCategorySettingsTests {
    @Test("events(in:) partitions the vocabulary by category")
    func eventsPartitionTheVocabulary() {
        let all = SemanticEvent.Category.allCases.flatMap { SemanticEventVocabulary.events(in: $0) }
        #expect(all.count == SemanticEventVocabulary.categories.count)
        #expect(Set(all) == Set(SemanticEventVocabulary.categories.keys))
        #expect(SemanticEventVocabulary.events(in: .group) == ["follow", "stop_follow"])
    }

    @Test("a cap saved by the window is what the soundpack plays under")
    func windowCapReachesThePlugin() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundpack-window-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var window = SoundpackConfig()
        window.muted = false
        window.setVolume(30, for: .world)
        window.save(to: url)

        var plugin = Soundpack(configURL: url)
        _ = plugin.install()
        let event = SemanticEvent(category: .world, name: "quest_ready", source: .gmcp(package: "comm.quest"))
        let gains = plugin.onSemanticEvent(event).compactMap { effect -> Double? in
            if case .playSound(let cue) = effect { cue.volume } else { nil }
        }
        #expect(gains == [SoundVolume.linearGain(forPercent: 30)])
        let spcat = plugin.handleCommand("spcat")
        let listing = try #require(spcat)
        let worldRow = listing.compactMap { effect -> [NoteSegment]? in
            if case .colourNote(let segments) = effect { segments } else { nil }
        }.first { $0.first?.text.contains("world") == true }
        #expect(worldRow?.last?.text == "30%")
    }
}
