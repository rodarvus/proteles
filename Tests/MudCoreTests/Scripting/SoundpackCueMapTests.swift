import Foundation
@testable import MudCore
import Testing

/// The event→cue map (S1 step 2, `docs/plans/S1_ITEM2_PROPOSAL.md`): the
/// version-1 upgrade, the `min(event, category, master)` cap, variants with no
/// immediate repeat, cues on any first-party event, and `spcat`.
@Suite("Soundpack — the cue map")
struct SoundpackCueMapTests {
    private func unmuted() -> Soundpack {
        var plugin = Soundpack(configURL: nil)
        _ = plugin.handleCommand("spmute")
        return plugin
    }

    private func files(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .playSound(let file, _, _) = $0 { file } else { nil }
        }
    }

    private func gains(_ effects: [ScriptEffect]) -> [Double] {
        effects.compactMap {
            if case .playSound(_, let volume, _) = $0 { volume } else { nil }
        }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("soundpack-cuemap-\(UUID().uuidString).json")
    }

    // MARK: - Version-1 upgrade

    /// The shape 0.8.x wrote: no `version`, one `file` per event.
    private let versionOne = Data("""
    {
      "debug" : false,
      "events" : {
        "tell" : { "file" : "mytell.wav", "pan" : -50, "volume" : 40 },
        "gossip" : { "volume" : 0 }
      },
      "globalVolume" : 80,
      "muted" : false,
      "systemSoundFallback" : true
    }
    """.utf8)

    @Test("A version-1 file loads with its custom file as a one-file list, everything else intact")
    func versionOneLoads() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try versionOne.write(to: url)

        let config = SoundpackConfig.load(from: url)
        #expect(config.version == SoundpackConfig.currentVersion)
        #expect(config.files(for: "tell") == ["mytell.wav"])
        #expect(config.volume(for: "tell") == 40)
        #expect(config.pan(for: "tell") == -50)
        #expect(config.volume(for: "gossip") == 0)
        #expect(config.files(for: "gossip") == ["gossip.wav"])
        #expect(config.globalVolume == 80)
        #expect(config.muted == false)
    }

    @Test("Loading a version-1 file rewrites it as version 2, once")
    func versionOneIsRewritten() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try versionOne.write(to: url)

        _ = SoundpackConfig.load(from: url)
        let rewritten = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(rewritten["version"] as? Int == 2)
        let tell = try #require((rewritten["events"] as? [String: Any])?["tell"] as? [String: Any])
        #expect(tell["files"] as? [String] == ["mytell.wav"])
        #expect(tell["file"] == nil)
        // A version-2 file is left alone.
        #expect(try SoundpackConfig.migrated(Data(contentsOf: url)) == nil)
    }

    @Test("A minimal hand-edited file still loads; malformed JSON is the defaults")
    func tolerantLoading() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"muted": false}"#.utf8).write(to: url)
        #expect(SoundpackConfig.load(from: url).muted == false)

        try Data("not json".utf8).write(to: url)
        #expect(SoundpackConfig.load(from: url) == SoundpackConfig())
    }

    @Test("Variants and category volumes round-trip through the file")
    func roundTrip() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var plugin = Soundpack(configURL: url)
        _ = plugin.handleCommand("spset tell wav add second.wav")
        _ = plugin.handleCommand("spcat combat 30")

        let reloaded = SoundpackConfig.load(from: url)
        #expect(reloaded.files(for: "tell") == ["tell.wav", "second.wav"])
        #expect(reloaded.volume(for: .combat) == 30)
        #expect(reloaded.volume(for: .world) == 100)
        #expect(reloaded.categories.count == 1) // deviations only
    }

    // MARK: - The cap

    @Test("A cue plays at the lowest of event, category and master")
    func capIsTheMinimum() throws {
        var config = SoundpackConfig()
        config.updateOverride(for: "tell") { $0.volume = 80 }
        config.setVolume(50, for: .communication)
        #expect(config.effectiveVolume(for: "tell") == 50)
        let cue = try #require(config.cue(for: "tell")?.cue)
        #expect(cue.volume == SoundVolume.linearGain(forPercent: 50))

        config.globalVolume = 30
        #expect(config.effectiveVolume(for: "tell") == 30)
        // Another category is unaffected by communication's cap.
        #expect(config.effectiveVolume(for: "level_up") == 30)
    }

    @Test("Event, category or master at 0 silences the event")
    func anyZeroSilences() {
        var event = SoundpackConfig()
        event.updateOverride(for: "tell") { $0.volume = 0 }
        var category = SoundpackConfig()
        category.setVolume(0, for: .communication)
        var global = SoundpackConfig()
        global.globalVolume = 0
        for config in [event, category, global] {
            #expect(config.cue(for: "tell") == nil)
        }
        #expect(category.cue(for: "level_up") != nil)
    }

    @Test("A category at 0 silences inline !!SOUND too (remote_sound is communication)")
    func categoryCapsInlineSound() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spcat communication 0")
        let effects = plugin.onGMCP(
            package: "comm.channel",
            json: #"{"chan":"gossip","msg":"!!SOUND(fanfare.wav)","player":"Eketra"}"#
        )
        #expect(files(effects).isEmpty)
    }

    // MARK: - Variants

    @Test("The pick never repeats the previous file when there is a choice")
    func noImmediateRepeat() {
        for count in [2, 3, 5] {
            var previous: Int?
            for _ in 0..<1000 {
                let pick = SoundpackConfig.pick(count: count, avoiding: previous) { Int.random(in: 0..<$0) }
                #expect((0..<count).contains(pick))
                #expect(pick != previous)
                previous = pick
            }
        }
        #expect(SoundpackConfig.pick(count: 1, avoiding: 0) { _ in 0 } == 0)
    }

    @Test("The pick skips over the previous index (injected draws)")
    func pickSkipsPrevious() {
        // Three files, previous 1: draws 0 and 1 map to indices 0 and 2.
        #expect(SoundpackConfig.pick(count: 3, avoiding: 1) { _ in 0 } == 0)
        #expect(SoundpackConfig.pick(count: 3, avoiding: 1) { _ in 1 } == 2)
        // No previous: a plain draw over every file.
        #expect(SoundpackConfig.pick(count: 3, avoiding: nil) { $0 - 1 } == 2)
    }

    @Test("wav add keeps the default as a variant; two variants alternate")
    func addAlternates() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spset tell wav add second.wav")
        #expect(plugin.config.files(for: "tell") == ["tell.wav", "second.wav"])
        var played: [String] = []
        for _ in 0..<6 {
            played += files(plugin.handleCommand("spfire tell") ?? [])
        }
        #expect(played.count == 6)
        for (first, second) in zip(played, played.dropFirst()) {
            #expect(first != second)
        }
    }

    @Test("wav remove edits the list, refuses the last file, and default restores")
    func removeAndDefault() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spset tell wav add second.wav")
        _ = plugin.handleCommand("spset tell wav remove tell.wav")
        #expect(plugin.config.files(for: "tell") == ["second.wav"])
        #expect(files(plugin.handleCommand("spfire tell") ?? []) == ["second.wav"])

        let missing = plugin.handleCommand("spset tell wav remove nope.wav") ?? []
        #expect(files(missing).isEmpty)
        #expect(plugin.config.files(for: "tell") == ["second.wav"])

        // The only file can't be removed: silencing is sptog's job.
        let last = plugin.handleCommand("spset tell wav remove second.wav") ?? []
        #expect(files(last).isEmpty)
        #expect(plugin.config.files(for: "tell") == ["second.wav"])

        _ = plugin.handleCommand("spset tell wav default")
        #expect(plugin.config.files(for: "tell") == ["tell.wav"])
    }

    // MARK: - Open vocabulary

    @Test("A tag-sourced event plays a cue once one is set; it has none by default")
    func tagEventCue() {
        var plugin = unmuted()
        let event = SemanticEvent(
            category: .affect, name: "affect_off", source: .tag(family: "spellups"), payload: ["spell": "1"]
        )
        #expect(files(plugin.onSemanticEvent(event)).isEmpty)
        _ = plugin.handleCommand("spset affect_off wav spell_off.wav")
        #expect(files(plugin.onSemanticEvent(event)) == ["spell_off.wav"])
    }

    @Test("Names outside the vocabulary are rejected and never stored")
    func unknownNamesRejected() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spset nosuchevent wav x.wav")
        _ = plugin.handleCommand("spset nosuchevent wav add x.wav")
        _ = plugin.handleCommand("sptog nosuchevent")
        #expect(plugin.config.events.isEmpty)
        #expect(!SoundpackConfig.isKnown("nosuchevent"))
        #expect(SoundpackConfig.isKnown("skill_gain"))
        #expect(SoundpackConfig.isKnown("tell"))
    }

    @Test("sptog all leaves events with no sound untouched")
    func toggleAllSkipsSilentEvents() {
        var plugin = unmuted()
        _ = plugin.handleCommand("sptog all")
        #expect(plugin.config.volume(for: "tell") == 0)
        #expect(plugin.config.events["affect_on"] == nil)
    }

    // MARK: - spcat

    @Test("spcat lists all eight categories at 100 by default")
    func spcatLists() {
        var plugin = unmuted()
        let rows = (plugin.handleCommand("spcat") ?? []).filter {
            if case .colourNote = $0 { true } else { false }
        }
        // The header note plus one row per category.
        #expect(rows.count == 1 + SemanticEvent.Category.allCases.count)
    }

    @Test("spcat sets one category, validates its input, and caps that category's cues")
    func spcatSets() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spcat Communication 50")
        #expect(plugin.config.volume(for: .communication) == 50)
        let tell = plugin.handleCommand("spfire tell") ?? []
        #expect(gains(tell) == [SoundVolume.linearGain(forPercent: 50)])
        let level = plugin.handleCommand("spfire level_up") ?? []
        #expect(gains(level) == [SoundVolume.linearGain(forPercent: 100)])

        _ = plugin.handleCommand("spcat nonsense 50")
        _ = plugin.handleCommand("spcat combat 101")
        _ = plugin.handleCommand("spcat combat loud")
        #expect(plugin.config.categories == ["communication": 50])

        _ = plugin.handleCommand("spcat communication 100")
        #expect(plugin.config.categories.isEmpty)
    }
}
