import Foundation
@testable import MudCore
import Testing

/// The Soundpack native plugin (#10): cue emission from lines + GMCP, the
/// reference volume model (per-event capped by global, percent→dB→linear),
/// mute gating, the sp* command surface, config persistence round-trips,
/// and the local-file-only `!!SOUND` degrade.
@Suite("Soundpack — the native plugin")
struct SoundpackPluginTests {
    /// A plugin that never touches disk (nil config URL), unmuted for tests.
    private func unmuted() -> Soundpack {
        var plugin = Soundpack(configURL: nil)
        _ = plugin.handleCommand("spmute")
        return plugin
    }

    private func cues(_ effects: [ScriptEffect]) -> [SoundCue] {
        effects.compactMap {
            if case .playSound(let file, let volume, let pan) = $0 {
                SoundCue(file: file, volume: volume, pan: pan)
            } else { nil }
        }
    }

    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    @Test("muted by default — no cues, even for a level-up")
    func mutedByDefault() {
        var plugin = Soundpack(configURL: nil)
        let disposition = plugin.onLine(line("You raise a level! You are now level 142."))
        #expect(disposition.effects.isEmpty)
        #expect(disposition.gag == false)
    }

    @Test("unmuted, a level-up line plays level_up.wav at full volume")
    func levelUpCue() {
        var plugin = unmuted()
        let disposition = plugin.onLine(line("You raise a level! You are now level 142."))
        #expect(cues(disposition.effects) == [SoundCue(file: "level_up.wav", volume: 1, pan: 0)])
    }

    @Test("comm.channel keys the event directly; unknown channels are silent")
    func channelCue() {
        var plugin = unmuted()
        let effects = plugin.onGMCP(
            package: "comm.channel",
            json: #"{"chan":"tell","msg":"Eketra tells you 'hi'","player":"Eketra"}"#
        )
        #expect(cues(effects) == [SoundCue(file: "tell.wav", volume: 1, pan: 0)])
        let unknown = plugin.onGMCP(
            package: "comm.channel",
            json: #"{"chan":"mysterychan","msg":"x","player":"Y"}"#
        )
        #expect(cues(unknown).isEmpty)
    }

    @Test("comm.quest ready and comm.repop fire their events")
    func questAndRepop() {
        var plugin = unmuted()
        let quest = plugin.onGMCP(package: "comm.quest", json: #"{"action":"ready"}"#)
        #expect(cues(quest) == [SoundCue(file: "quest_ready.wav", volume: 1, pan: 0)])
        let repop = plugin.onGMCP(package: "comm.repop", json: #"{"zone":"aylor"}"#)
        #expect(cues(repop) == [SoundCue(file: "zone_repop.wav", volume: 1, pan: 0)])
    }

    @Test("volume model: per-event volume capped by global, dB curve applied")
    func volumeModel() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spset tell volume 50") // -20 dB → 0.1
        var disposition = plugin.onGMCP(
            package: "comm.channel", json: #"{"chan":"tell","msg":"m","player":"E"}"#
        )
        var cue = try? #require(cues(disposition).first)
        #expect(abs((cue?.volume ?? 0) - 0.1) < 1e-9)

        _ = plugin.handleCommand("spvol 50") // global cap below the event's 100
        disposition = plugin.onGMCP(
            package: "comm.channel", json: #"{"chan":"gossip","msg":"m","player":"E"}"#
        )
        cue = try? #require(cues(disposition).first)
        #expect(abs((cue?.volume ?? 0) - 0.1) < 1e-9)
    }

    @Test("volume 0 disables the event; sptog re-enables at 100")
    func toggling() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spset tell volume 0")
        let silent = plugin.onGMCP(
            package: "comm.channel", json: #"{"chan":"tell","msg":"m","player":"E"}"#
        )
        #expect(cues(silent).isEmpty)
        _ = plugin.handleCommand("sptog tell")
        let restored = plugin.onGMCP(
            package: "comm.channel", json: #"{"chan":"tell","msg":"m","player":"E"}"#
        )
        #expect(cues(restored).first?.volume == 1)
    }

    @Test("panning override lands on the cue (-100 → hard left)")
    func panning() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spset tell panning -100")
        let effects = plugin.onGMCP(
            package: "comm.channel", json: #"{"chan":"tell","msg":"m","player":"E"}"#
        )
        #expect(cues(effects).first?.pan == -1)
    }

    @Test("custom wav override plays instead of the default; 'wav default' resets")
    func customWav() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spset tell wav mytell.wav")
        var effects = plugin.onGMCP(
            package: "comm.channel", json: #"{"chan":"tell","msg":"m","player":"E"}"#
        )
        #expect(cues(effects).first?.file == "mytell.wav")
        _ = plugin.handleCommand("spset tell wav default")
        effects = plugin.onGMCP(
            package: "comm.channel", json: #"{"chan":"tell","msg":"m","player":"E"}"#
        )
        #expect(cues(effects).first?.file == "tell.wav")
    }

    @Test("!!SOUND(name) in a channel message plays locally; URLs are dropped")
    func inlineSound() {
        var plugin = unmuted()
        let local = plugin.onGMCP(
            package: "comm.channel",
            json: #"{"chan":"gossip","msg":"hear this !!SOUND(fanfare.wav)","player":"Eketra"}"#
        )
        #expect(cues(local).map(\.file) == ["fanfare.wav", "gossip.wav"])

        let remote = plugin.onGMCP(
            package: "comm.channel",
            json: #"{"chan":"gossip","msg":"!!SOUND(http://evil.example/x.wav)","player":"Eketra"}"#
        )
        #expect(cues(remote).map(\.file) == ["gossip.wav"]) // URL ignored, channel cue still fires
    }

    @Test("own !!SOUND sends aren't replayed (char.base name tracked while muted)")
    func selfSoundSkipped() {
        var plugin = Soundpack(configURL: nil)
        _ = plugin.onGMCP(package: "char.base", json: #"{"name":"Rodarvus","class":"Ranger"}"#)
        _ = plugin.handleCommand("spmute")
        let effects = plugin.onGMCP(
            package: "comm.channel",
            json: #"{"chan":"gossip","msg":"!!SOUND(fanfare.wav)","player":"Rodarvus"}"#
        )
        #expect(cues(effects).map(\.file) == ["gossip.wav"])
    }

    @Test("remote_sound volume 0 disables inline sounds")
    func inlineSoundDisabled() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spset remote_sound volume 0")
        let effects = plugin.onGMCP(
            package: "comm.channel",
            json: #"{"chan":"gossip","msg":"!!SOUND(fanfare.wav)","player":"Eketra"}"#
        )
        #expect(cues(effects).map(\.file) == ["gossip.wav"])
    }

    @Test("spmute toggles and confirms with channel_on.wav both ways")
    func muteConfirmation() {
        var plugin = Soundpack(configURL: nil)
        let enabled = plugin.handleCommand("spmute")
        #expect(cues(enabled ?? []).map(\.file) == ["channel_on.wav"])
        #expect(plugin.config.muted == false)
        let disabled = plugin.handleCommand("spmute")
        #expect(cues(disabled ?? []).map(\.file) == ["channel_on.wav"])
        #expect(plugin.config.muted == true)
    }

    @Test("spvol shows and validates; spset rejects bad values + unknown events")
    func commandValidation() {
        var plugin = unmuted()
        #expect(plugin.handleCommand("spvol") != nil)
        #expect(plugin.handleCommand("spvol 150") != nil) // error note, no crash
        #expect(plugin.config.globalVolume == 100)
        #expect(plugin.handleCommand("spset tell volume 999") != nil)
        #expect(plugin.config.volume(for: "tell") == 100)
        #expect(plugin.handleCommand("spset nosuchevent volume 50") != nil)
        #expect(plugin.handleCommand("notacommand") == nil) // unhandled → sent to MUD
        #expect(plugin.handleCommand("spseteverything") == nil)
    }

    @Test("spset lists all 69 events; sptog all flips everything")
    func listingAndToggleAll() {
        var plugin = unmuted()
        let listing = plugin.handleCommand("spset") ?? []
        // Header rows + one colourNote per event.
        let rows = listing.filter { if case .colourNote = $0 { true } else { false } }
        #expect(rows.count >= SoundEventClassifier.defaults.count)
        _ = plugin.handleCommand("sptog all")
        #expect(plugin.config.volume(for: "tell") == 0)
        #expect(plugin.config.volume(for: "level_up") == 0)
        let silent = plugin.onLine(line("You raise a level! You are now level 5."))
        #expect(cues(silent.effects).isEmpty)
    }

    @Test("spfire fires an event through config (the S&D TriggerEvent bridge)")
    func spfire() {
        var plugin = unmuted()
        let fired = plugin.handleCommand("spfire quest_target_found") ?? []
        #expect(cues(fired) == [SoundCue(file: "quest_target_found.wav", volume: 1, pan: 0)])
        // Respects per-event config…
        _ = plugin.handleCommand("spset quest_target_found volume 0")
        #expect(cues(plugin.handleCommand("spfire quest_target_found") ?? []).isEmpty)
        // …and the master mute; unknown events are consumed silently (never
        // leak to the MUD as a bogus command).
        // `?.isEmpty == true` (not nil): consumed-with-no-cue, never sent on.
        var muted = Soundpack(configURL: nil)
        #expect(muted.handleCommand("spfire tell")?.isEmpty == true)
        #expect(plugin.handleCommand("spfire nosuchevent")?.isEmpty == true)
    }

    @Test("config round-trips through soundpack.json (deviations only)")
    func configPersistence() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundpack-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var plugin = Soundpack(configURL: url)
        _ = plugin.handleCommand("spmute") // unmute → save
        _ = plugin.handleCommand("spset tell volume 40")
        _ = plugin.handleCommand("spvol 80")

        let reloaded = Soundpack(configURL: url)
        #expect(reloaded.config.muted == false)
        #expect(reloaded.config.globalVolume == 80)
        #expect(reloaded.config.volume(for: "tell") == 40)
        // Defaults aren't persisted: only the deviating event is on disk.
        #expect(reloaded.config.events.count == 1)
    }

    @Test("a hand-edited partial file decodes with defaults intact")
    func partialFileTolerance() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundpack-partial-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"muted": false}"#.utf8).write(to: url)

        let plugin = Soundpack(configURL: url)
        #expect(plugin.config.muted == false)
        #expect(plugin.config.globalVolume == 100)
        #expect(plugin.config.systemSoundFallback == true)
    }

    @Test("debug mode notes fired events alongside the cue")
    func debugNotes() {
        var plugin = unmuted()
        _ = plugin.handleCommand("spdebug")
        let disposition = plugin.onLine(line("You die."))
        let hasDebugNote = disposition.effects.contains {
            if case .colourNote(let segments) = $0 {
                segments.contains { $0.text.contains("death has fired") }
            } else { false }
        }
        #expect(hasDebugNote)
        #expect(cues(disposition.effects).map(\.file) == ["death.wav"])
    }

    // MARK: - Chat Echo mute integration (#55)

    /// The full registry path the live session takes: ChatEcho + Soundpack
    /// registered together, the registry pre-answering `checkIfMuted` per
    /// `comm.channel` dispatch (the reference soundpack's `CallPlugin` into
    /// the chat plugin before any cue).
    /// Registry with both plugins, soundpack unmuted THROUGH the registry —
    /// registration re-runs `install()`, which re-reads config and would wipe
    /// a pre-registration unmute (the launch-order bug #9 already hit once).
    private func chatAndSound() -> NativePluginRegistry {
        var registry = NativePluginRegistry()
        registry.register(ChatEcho())
        registry.register(Soundpack(configURL: nil))
        _ = registry.handleCommand("spmute")
        return registry
    }

    @Test("a Chat Echo-muted speaker's channel line plays no cue; unmuting restores it")
    func chatEchoMuteSuppressesCues() {
        var registry = chatAndSound()

        let gossip = #"{"chan":"gossip","msg":"Villain gossips hi","player":"Villain"}"#
        #expect(!cues(registry.onGMCP(package: "comm.channel", json: gossip)).isEmpty)

        _ = registry.handleCommand("chats mute Villain")
        #expect(cues(registry.onGMCP(package: "comm.channel", json: gossip)).isEmpty)

        // Another speaker on the same channel still cues.
        let friendly = #"{"chan":"gossip","msg":"Friend gossips yo","player":"Friend"}"#
        #expect(!cues(registry.onGMCP(package: "comm.channel", json: friendly)).isEmpty)

        _ = registry.handleCommand("chats unmute Villain")
        #expect(!cues(registry.onGMCP(package: "comm.channel", json: gossip)).isEmpty)
    }

    @Test("a muted speaker's inline !!SOUND is suppressed too (reference early-return)")
    func chatEchoMuteSuppressesInlineSound() {
        var registry = chatAndSound()
        _ = registry.handleCommand("chats mute Villain")

        let inline = #"{"chan":"gossip","msg":"hey !!SOUND(alarm.wav)","player":"Villain"}"#
        #expect(cues(registry.onGMCP(package: "comm.channel", json: inline)).isEmpty)
    }

    @Test("Chat Echo disabled = nobody is muted (CallPlugin-to-missing-plugin semantics)")
    func disabledChatEchoMutesNothing() {
        var registry = chatAndSound()
        _ = registry.handleCommand("chats mute Villain")
        registry.setEnabled(false, id: ChatEcho.pluginID)

        let gossip = #"{"chan":"gossip","msg":"Villain gossips hi","player":"Villain"}"#
        #expect(!cues(registry.onGMCP(package: "comm.channel", json: gossip)).isEmpty)
    }
}
