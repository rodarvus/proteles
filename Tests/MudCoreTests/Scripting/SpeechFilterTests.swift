import Foundation
@testable import MudCore
import Testing

/// The TTS decision pipeline (#9): symbol-art stripping, the three modes,
/// tell-interrupt priority, and the speech.json config round-trip.
@Suite("SpeechFilter + SpeechConfig")
struct SpeechFilterTests {
    // MARK: - Normalization

    @Test("symbol runs of 3+ become a space; short runs survive")
    func symbolRuns() {
        #expect(SpeechFilter.normalized("*** PRESS RETURN ***") == "PRESS RETURN")
        #expect(SpeechFilter.normalized("=== Aylor ===") == "Aylor")
        #expect(SpeechFilter.normalized("didn't stop") == "didn't stop")
        #expect(SpeechFilter.normalized("hp: 100 | mn: 50") == "hp: 100 | mn: 50")
        #expect(SpeechFilter.normalized("----------------------").isEmpty)
        #expect(SpeechFilter.normalized("   ").isEmpty)
    }

    @Test("box-drawing frames are stripped")
    func boxDrawing() {
        #expect(SpeechFilter.normalized("┌────────┐").isEmpty)
        #expect(SpeechFilter.normalized("│ Quests │").contains("Quests"))
    }

    // MARK: - Modes

    @Test("off mode speaks nothing")
    func offMode() {
        #expect(SpeechFilter.decision(forDisplayedLine: "Eketra tells you 'hi'", mode: .off) == nil)
    }

    @Test("everything mode speaks prose; blank/art lines stay silent")
    func everythingMode() {
        let prose = SpeechFilter.decision(forDisplayedLine: "The Grand City of Aylor", mode: .everything)
        #expect(prose?.text == "The Grand City of Aylor")
        #expect(prose?.interrupt == false)
        #expect(SpeechFilter.decision(forDisplayedLine: "==========", mode: .everything) == nil)
    }

    @Test("alerts mode speaks soundpack-worthy lines and tells, nothing else")
    func alertsMode() {
        #expect(SpeechFilter.decision(
            forDisplayedLine: "You raise a level! You are now level 142.", mode: .alerts
        ) != nil)
        #expect(SpeechFilter.decision(
            forDisplayedLine: "Eketra tells you 'run'", mode: .alerts
        ) != nil)
        #expect(SpeechFilter.decision(
            forDisplayedLine: "A giant rat scampers past.", mode: .alerts
        ) == nil)
    }

    @Test("tells interrupt; ordinary lines queue")
    func tellPriority() {
        let tell = SpeechFilter.decision(forDisplayedLine: "Eketra tells you 'hi'", mode: .everything)
        #expect(tell?.interrupt == true)
        let line = SpeechFilter.decision(forDisplayedLine: "You sit down.", mode: .everything)
        #expect(line?.interrupt == false)
    }

    // MARK: - Config

    @Test("speech.json round-trips; partial hand-edits keep defaults")
    func configRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = SpeechConfig()
        config.mode = .alerts
        config.wordsPerMinute = 350
        config.voice = "Samantha"
        config.save(to: url)
        let loaded = SpeechConfig.load(from: url)
        #expect(loaded == config)

        try Data(#"{"wordsPerMinute": 400}"#.utf8).write(to: url)
        let partial = SpeechConfig.load(from: url)
        #expect(partial.wordsPerMinute == 400)
        #expect(partial.mode == .off)
        #expect(partial.voiceOverRouting == false)
    }
}

/// The TextToSpeech plugin's command surface (#9).
@Suite("TextToSpeech — the native plugin")
struct TextToSpeechPluginTests {
    private func plugin() -> TextToSpeech {
        TextToSpeech(configURL: nil)
    }

    @Test("off by default; install pushes the persisted mode")
    func installPushesMode() {
        var tts = plugin()
        let effects = tts.install()
        #expect(effects.contains(.setSpeechMode(.off)))
        #expect(effects.contains(.speechConfigChanged))
    }

    @Test("tts on/alerts/off set the mode and push it to the session")
    func modeCommands() {
        var tts = plugin()
        let on = tts.handleCommand("tts on") ?? []
        #expect(on.contains(.setSpeechMode(.everything)))
        #expect(tts.config.mode == .everything)

        let alerts = tts.handleCommand("tts alerts") ?? []
        #expect(alerts.contains(.setSpeechMode(.alerts)))

        let off = tts.handleCommand("tts off") ?? []
        #expect(off.contains(.setSpeechMode(.off)))
        #expect(off.contains(.stopSpeaking))
    }

    @Test("tts rate validates 80-600 and pushes a config reload + sample")
    func rateCommand() {
        var tts = plugin()
        let effects = tts.handleCommand("tts rate 350") ?? []
        #expect(tts.config.wordsPerMinute == 350)
        #expect(effects.contains(.speechConfigChanged))
        _ = tts.handleCommand("tts rate 9000")
        #expect(tts.config.wordsPerMinute == 350)
    }

    @Test("tts voice sets and resets; bare voice shows")
    func voiceCommand() {
        var tts = plugin()
        _ = tts.handleCommand("tts voice Samantha")
        #expect(tts.config.voice == "Samantha")
        _ = tts.handleCommand("tts voice default")
        #expect(tts.config.voice == nil)
        #expect(tts.handleCommand("tts voice") != nil)
    }

    @Test("tts say speaks with interrupt; tts last requests the buffer")
    func sayAndLast() {
        var tts = plugin()
        let say = tts.handleCommand("tts say incoming raid") ?? []
        #expect(say == [.speak(text: "incoming raid", interrupt: true)])
        let last = tts.handleCommand("tts last 5") ?? []
        #expect(last == [.speakRecentOutput(count: 5)])
        let one = tts.handleCommand("tts last") ?? []
        #expect(one == [.speakRecentOutput(count: 1)])
    }

    @Test("tts stop flushes; unrelated input passes through")
    func stopAndPassthrough() {
        var tts = plugin()
        #expect(tts.handleCommand("tts stop") == [.stopSpeaking])
        #expect(tts.handleCommand("ttsx") == nil)
        #expect(tts.handleCommand("look") == nil)
    }
}

/// proteles.speak across the compat shim (#9).
@Suite("proteles.speak host fn")
struct ProtelesSpeakTests {
    @Test("proteles.speak records a .speak effect")
    func speakEffect() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("proteles.speak('target nearby', true)")
        #expect(effects == [.speak(text: "target nearby", interrupt: true)])
        let queued = try await lua.run("proteles.speak('hello')")
        #expect(queued == [.speak(text: "hello", interrupt: false)])
    }
}
