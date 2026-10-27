import Foundation
@testable import MudCore
import Testing

/// Notification sounds through the cue pipeline (S1 step 5, #83, D-127 (4)):
/// a notification's sound is an emitted `notification` event, made into a
/// cue by the cue map in its own category, not silenced by the soundpack's
/// mute (`docs/plans/S1_ITEM5_PROPOSAL.md`).
@Suite("notification sound — a cue, not the banner's", .serialized)
struct NotificationSoundTests {
    private actor Collector {
        var notes: [ProtelesNotification] = []
        func append(_ note: ProtelesNotification) {
            notes.append(note)
        }
    }

    private func firstCue(_ effects: [ScriptEffect]) -> SoundCue? {
        effects.lazy.compactMap { effect -> SoundCue? in
            if case .playSound(let cue) = effect { cue } else { nil }
        }.first
    }

    /// An engine with the soundpack at its default: **muted**.
    private func engine(_ commands: [String] = []) async throws -> ScriptEngine {
        let engine = try ScriptEngine()
        await engine.registerNativePlugin(Soundpack(configURL: nil))
        for command in commands {
            _ = await engine.expandInputForDispatch(command)
        }
        return engine
    }

    // MARK: - The choice → the file

    @Test("each sound choice names its file; Silent names none", arguments: [
        (NotificationRule.Sound.default, SoundCue.systemAlertFile as String?),
        (.glass, "Glass.aiff"), (.ping, "Ping.aiff"), (.submarine, "Submarine.aiff"),
        (.hero, "Hero.aiff"), (.funk, "Funk.aiff"), (.silent, nil)
    ])
    func choiceFiles(sound: NotificationRule.Sound, file: String?) {
        #expect(sound.cueFile == file)
        let event = ProtelesNotification(title: "t", body: "b", sound: sound).soundCueEvent
        #expect(event?.payload[TriggerSound.filePayloadKey] == file)
        if let event {
            #expect(event.category == .notification && event.name == ProtelesNotification.soundEvent)
        }
    }

    @Test("built-in tells carry the Default sound")
    func tellsCarryDefault() {
        let chat = ChatLine(
            id: 0,
            timestamp: Date(),
            channel: "tell",
            player: "Eketra",
            line: Line(id: LineID(0), text: "Eketra tells you 'hi'")
        )
        let note = NotificationMatcher().notification(for: chat, characterName: "Rodarvus")
        #expect(note?.sound == .default)
    }

    // MARK: - The cue map

    @Test("a muted soundpack still makes a notification's cue, under the notification caps")
    func mutedSoundpackStillCues() async throws {
        let engine = try await engine(["spcat notification 40"])
        let event = try #require(ProtelesNotification(title: "t", body: "b", sound: .glass).soundCueEvent)
        #expect(await firstCue(engine.emit(event)) == SoundCue(
            file: "Glass.aiff",
            volume: SoundVolume.linearGain(forPercent: 40),
            pan: 0,
            event: ProtelesNotification.soundEvent
        ))
    }

    @Test("spcat notification 0 silences it")
    func categoryZeroSilences() async throws {
        let engine = try await engine(["spcat notification 0"])
        let event = try #require(ProtelesNotification(title: "t", body: "b").soundCueEvent)
        #expect(await firstCue(engine.emit(event)) == nil)
    }

    @Test("an emitted event reaches a plugin that wants no classified events")
    func emitIgnoresTheClassificationGate() throws {
        var registry = NativePluginRegistry()
        registry.register(Soundpack(configURL: nil)) // muted: wants no events
        #expect(!registry.wantsSemanticEvents, "classification must stay off while muted")
        let event = try #require(ProtelesNotification(title: "t", body: "b").soundCueEvent)
        #expect(firstCue(registry.emit(event))?.file == SoundCue.systemAlertFile)
        #expect(firstCue(registry.onSemanticEvent(event)) == nil, "classified fan-out stays gated")
    }

    // MARK: - The session

    @Test("a published notification carries its cue while the soundpack is muted; a duplicate is coalesced")
    func sessionAttachesCue() async throws {
        let engine = try await engine()
        let session = SessionController(scriptEngine: engine, makeConnection: { InMemoryConnection() })
        await session.setNotificationsEnabled(true)

        let notes = Collector()
        let pump = Task {
            for await note in session.notifications {
                await notes.append(note)
            }
        }
        await session.notifyFromScript(title: "Quest ready", body: "go")
        await session.notifyFromScript(title: "Quest ready", body: "go") // coalesced
        let arrived = await SessionTestSupport.poll { await !notes.notes.isEmpty }
        #expect(arrived)
        try? await Task.sleep(for: .milliseconds(100))
        let received = await notes.notes
        #expect(received.count == 1)
        #expect(received.first?.cue?.file == SoundCue.systemAlertFile)
        #expect(received.first?.cue?.event == ProtelesNotification.soundEvent)
        pump.cancel()
    }
}
