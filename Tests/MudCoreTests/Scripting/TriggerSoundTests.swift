import Foundation
@testable import MudCore
import Testing

/// The trigger `sound` action (S1 step 4, #83, D-127 (3)): a trigger's sound
/// is an event into the layer, played by the cue map under its caps and the
/// soundpack's mute (`docs/plans/S1_ITEM4_PROPOSAL.md`).
@Suite("trigger sound — an event into the pipeline", .serialized)
struct TriggerSoundTests {
    /// An engine with an unmuted soundpack, configured through the engine:
    /// registering re-runs `install()`, which would undo earlier settings.
    private func engine(_ commands: [String] = []) async throws -> ScriptEngine {
        let engine = try ScriptEngine()
        await engine.registerNativePlugin(Soundpack(configURL: nil))
        for command in ["spmute"] + commands {
            _ = await engine.expandInputForDispatch(command)
        }
        return engine
    }

    private func cues(_ disposition: ScriptEngine.LineDisposition) -> [SoundCue] {
        disposition.effects.compactMap { effect in
            if case .playSound(let cue) = effect { cue } else { nil }
        }
    }

    private typealias Disposition = ScriptEngine.LineDisposition

    private func fire(_ trigger: Trigger, on engine: ScriptEngine) async throws -> Disposition {
        try await engine.addTrigger(trigger)
        return await engine.process(Line(id: LineID(0), text: "The beacon flares."))
    }

    // MARK: - Emission

    @Test("an event sound plays that event's cue")
    func eventSoundPlaysItsCue() async throws {
        let trigger = Trigger(pattern: .substring("beacon"), sound: .event(name: "tell"))
        let played = try await cues(fire(trigger, on: engine()))
        #expect(played.map(\.file) == ["tell.wav"])
        #expect(played.first?.event == "tell")
    }

    @Test("a file sound plays as trigger_sound, under the custom category and its own volume")
    func fileSoundUnderCaps() async throws {
        let trigger = Trigger(pattern: .substring("beacon"), sound: .file(name: "beacon.wav"))
        let capped = try await cues(fire(trigger, on: engine(["spcat custom 40"])))
        #expect(capped == [SoundCue(
            file: "beacon.wav",
            volume: SoundVolume.linearGain(forPercent: 40),
            pan: 0,
            event: TriggerSound.triggerSoundEvent
        )])

        let lowered = try await engine(["spcat custom 40", "spset trigger_sound volume 20"])
        let lower = try await cues(fire(trigger, on: lowered))
        #expect(lower.map(\.volume) == [SoundVolume.linearGain(forPercent: 20)])
    }

    @Test("a trigger that hides its line still plays its sound")
    func gaggedTriggerStillPlays() async throws {
        let trigger = Trigger(pattern: .substring("beacon"), gag: true, sound: .file(name: "beacon.wav"))
        let disposition = try await fire(trigger, on: engine())
        #expect(disposition.gag)
        #expect(cues(disposition).map(\.file) == ["beacon.wav"])
    }

    @Test("the soundpack's mute silences trigger sounds (Q1 (a))")
    func mutedSoundpackIsSilent() async throws {
        let engine = try await engine(["spmute"]) // unmuted, then muted again
        let trigger = Trigger(pattern: .substring("beacon"), sound: .file(name: "beacon.wav"))
        #expect(try await cues(fire(trigger, on: engine)).isEmpty)
    }

    @Test("no sound, an unknown event, or an empty file plays nothing", arguments: [
        nil, TriggerSound.event(name: "no_such_event"), .file(name: "")
    ])
    func silentCases(sound: TriggerSound?) async throws {
        let trigger = Trigger(pattern: .substring("beacon"), sound: sound)
        #expect(try await cues(fire(trigger, on: engine())).isEmpty)
    }

    @Test("the emitted event is a prose-tier event named for its trigger")
    func eventShape() {
        let event = TriggerSound.file(name: "x.wav").event(for: "pk1")
        #expect(event == SemanticEvent(
            category: .custom,
            name: TriggerSound.triggerSoundEvent,
            source: .pattern(rule: "trigger.pk1"),
            payload: [TriggerSound.filePayloadKey: "x.wav"]
        ))
        #expect(TriggerSound.event(name: "level_up").event(for: "t")?.category == .progression)
    }

    // MARK: - Storage

    @Test("a stored trigger without a sound decodes silent; both kinds round-trip")
    func storage() throws {
        let old = #"""
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","pattern":{"substring":{"_0":"x"}},
         "caseSensitive":false,"enabled":true,"sequence":100,"continueEvaluation":true,
         "oneShot":false,"gag":false}
        """#
        #expect(try JSONDecoder().decode(Trigger.self, from: Data(old.utf8)).sound == nil)
        for sound in [TriggerSound.event(name: "tell"), .file(name: "a b.wav")] {
            let trigger = Trigger(pattern: .substring("x"), sound: sound)
            let decoded = try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(trigger))
            #expect(decoded.sound == sound)
        }
    }

    // MARK: - Playback discipline

    @Test("trigger file sounds are rate-limited per file, not as one event")
    func governorKeysTriggerSoundsByFile() {
        func cue(_ file: String) -> SoundCue {
            SoundCue(file: file, volume: 1, pan: 0, event: TriggerSound.triggerSoundEvent)
        }
        var governor = CueGovernor()
        #expect(governor.admit(cue("a.wav"), at: 0) == .play)
        #expect(governor.admit(cue("b.wav"), at: 0.1) == .play)
        #expect(governor.admit(cue("a.wav"), at: 0.2) == .drop)
    }

    // MARK: - Import

    @Test("MUSHclient's sound attribute keeps only the file name", arguments: [
        (#"C:\Windows\Media\Cityscape\Windows Error.wav"#, TriggerSound.file(name: "Windows Error.wav")),
        ("sounds/alert.wav", .file(name: "alert.wav")),
        ("alert.wav", .file(name: "alert.wav")),
        ("(No sound)", nil),
        ("  ", nil)
    ])
    func importedAttribute(attribute: String, expected: TriggerSound?) {
        #expect(TriggerSound.imported(attribute) == expected)
    }

    @Test("world-file and plugin triggers carry their sound across")
    func importMapsSound() throws {
        let mcl = #"""
        <muclient><world name="W" site="h" port="23"></world>
        <triggers>
          <trigger match="revenge" enabled="y" sound="C:\Windows\Media\x.wav"><send></send></trigger>
          <trigger match="quiet" enabled="y" sound="(No sound)"><send></send></trigger>
        </triggers></muclient>
        """#
        let world = try #require(MUSHclientWorldParser.parse(Data(mcl.utf8)))
        let triggers = MUSHclientScriptMapping.triggers(from: world.triggers)
        #expect(triggers.first { $0.pattern == .wildcard("revenge") }?.sound == .file(name: "x.wav"))
        #expect(triggers.first { $0.pattern == .wildcard("quiet") }?.sound == nil)

        let plugin = PluginMapping.trigger(["match": "pk", "sound": #"C:\a\pk.wav"#], send: "")
        #expect(plugin.sound == .file(name: "pk.wav"))
        #expect(PluginMapping.trigger(["match": "pk"], send: "").sound == nil)
    }
}
