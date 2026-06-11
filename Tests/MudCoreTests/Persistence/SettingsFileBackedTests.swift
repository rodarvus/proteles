import Foundation
@testable import MudCore
import Testing

/// The shared `Settings/*.json` disk contract (#58 dedup). The conformers'
/// own suites cover their fields; this pins the *shared* behaviour so the
/// extracted protocol provably matches what SoundpackConfig/SpeechConfig
/// each did before: pretty + sorted output, tolerant loads, atomic writes
/// into a created parent directory.
@Suite("SettingsFileBacked — the shared Settings/*.json contract")
struct SettingsFileBackedTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-file-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test("save writes pretty-printed, sorted-key JSON (hand-editable format)")
    func savedFormatIsPrettyAndSorted() throws {
        let url = tempURL("soundpack.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var config = SoundpackConfig()
        config.muted = false
        config.globalVolume = 80
        config.save(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        // Sorted keys: "debug" before "events" before "globalVolume" …
        let debugIndex = try #require(text.range(of: "\"debug\"")?.lowerBound)
        let eventsIndex = try #require(text.range(of: "\"events\"")?.lowerBound)
        let volumeIndex = try #require(text.range(of: "\"globalVolume\"")?.lowerBound)
        #expect(debugIndex < eventsIndex && eventsIndex < volumeIndex)
        // Pretty-printed: multi-line.
        #expect(text.contains("\n"))
    }

    @Test("save creates the parent directory on demand")
    func saveCreatesParentDirectory() {
        let url = tempURL("speech.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

        SpeechConfig().save(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("missing, malformed, and nil-URL loads are the defaults")
    func tolerantLoads() throws {
        #expect(SoundpackConfig.load(from: nil) == SoundpackConfig())
        #expect(SpeechConfig.load(from: tempURL("missing.json")) == SpeechConfig())

        let url = tempURL("garbage.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json {{{".utf8).write(to: url)
        #expect(SoundpackConfig.load(from: url) == SoundpackConfig())
        #expect(SpeechConfig.load(from: url) == SpeechConfig())
    }

    @Test("defaultURL lands under Settings/ with the conformer's name")
    func defaultURLs() throws {
        #expect(try SoundpackConfig.defaultURL().lastPathComponent == "soundpack.json")
        #expect(try SpeechConfig.defaultURL().lastPathComponent == "speech.json")
        #expect(
            try SoundpackConfig.defaultURL().deletingLastPathComponent().lastPathComponent == "Settings"
        )
    }
}
