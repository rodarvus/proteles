import Foundation
@testable import MudCore
import Testing

/// `PlaySound` across the two Lua runtimes + the volume model (#10). The
/// MUSHclient units are dB (0 = full, −100 min; out-of-range coerces to
/// FULL volume — `methods_sounds.cpp`) and pan −100…100; the host converts
/// to the linear gain / −1…1 pan the `.playSound` effect carries.
@Suite("PlaySound — shim + S&D host + volume model")
struct PlaySoundShimTests {
    // MARK: - Volume model

    @Test("soundpack percent→dB curve: 100% = 0 dB, 50% = −20 dB, 0% = −40 dB")
    func percentCurve() {
        #expect(SoundVolume.decibels(forPercent: 100) == 0)
        #expect(SoundVolume.decibels(forPercent: 50) == -20)
        #expect(SoundVolume.decibels(forPercent: 0) == -40)
    }

    @Test("dB→linear gain: 0 dB = 1; −20 dB = 0.1; above 0 dB clamps to 1")
    func linearGain() {
        #expect(SoundVolume.linearGain(forDecibels: 0) == 1)
        #expect(abs(SoundVolume.linearGain(forDecibels: -20) - 0.1) < 1e-12)
        #expect(SoundVolume.linearGain(forDecibels: 6) == 1)
    }

    @Test("PlaySound coercion: out-of-range dB (S&D's 100) → full volume")
    func playSoundVolumeCoercion() {
        #expect(SoundVolume.playSoundGain(volumeDb: 100) == 1) // S&D's cues
        #expect(SoundVolume.playSoundGain(volumeDb: -101) == 1)
        #expect(abs(SoundVolume.playSoundGain(volumeDb: -20) - 0.1) < 1e-12)
    }

    @Test("PlaySound pan: −100…100 maps to −1…1; out of range → centered")
    func playSoundPan() {
        #expect(SoundVolume.playSoundPan(mushPan: -100) == -1)
        #expect(SoundVolume.playSoundPan(mushPan: 50) == 0.5)
        #expect(SoundVolume.playSoundPan(mushPan: 250) == 0)
    }

    // MARK: - Compat shim (generic third-party plugins)

    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("shim PlaySound emits a .playSound effect with converted units")
    func shimPlaySound() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("PlaySound(0, 'tell.wav', false, -20, 50)")
        #expect(effects.count == 1)
        guard case .playSound(let file, let volume, let pan) = effects[0] else {
            Issue.record("expected .playSound, got \(effects)")
            return
        }
        #expect(file == "tell.wav")
        #expect(abs(volume - 0.1) < 1e-12)
        #expect(pan == 0.5)
    }

    @Test("shim Sound(file) plays at full volume, centered")
    func shimSound() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("Sound('beep-01.wav')")
        #expect(effects == [.playSound(file: "beep-01.wav", volume: 1, pan: 0)])
    }

    @Test("shim PlaySound with an empty filename returns eBadParameter, no effect")
    func shimPlaySoundEmpty() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run(
            "assert(PlaySound(0, '', false, 0, 0) == error_code.eBadParameter)"
        )
        #expect(effects.isEmpty)
    }

    @Test("shim StopSound/GetSoundStatus are benign (fire-and-forget player)")
    func shimSoundStatus() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run(
            "assert(StopSound(1) == error_code.eOK); assert(GetSoundStatus(1) == -3)"
        )
        #expect(effects.isEmpty)
    }

    @Test("error_code table matches MUSHclient errors.h (the S&D fixture)")
    func errorCodes() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("""
        assert(error_code.eVariableNotFound == 30019)
        assert(error_code.eBadParameter == 30046)
        assert(error_code.eCannotPlaySound == 30004)
        """)
    }

    // MARK: - S&D host (dedicated runtime, curated bindings)

    @Test("S&D sounds default ON and TriggerEvent bridges to spfire (live-test fix)")
    func sndSoundLayers() async throws {
        try #require(SnDFixture.install(), "S&D test fixture missing")
        let host = try SearchAndDestroyHost()
        try await host.load()
        // Layer 1: with no saved variable, the sound default resolves "on"
        // because the native Soundpack answers as the installed+enabled
        // MUSHclient soundpack (all three layers were dead against the
        // all-false IsPluginInstalled stub — 2026-06-11 live test).
        #expect(await host.evaluate("tostring(is_sound_enabled())") == "true")
        // Layer 2: `xset sound` can actually toggle — download_sounds reports
        // success for our local cues (the first-cut no-op never called back,
        // so enabling was silently impossible).
        // (The Lua assert is the check; run() also appends the host's
        // shim-state probe effect, so the effect list isn't empty.)
        _ = try await host.run("""
        local ok = nil
        download_sounds(function(success) ok = success end)
        assert(ok == true, "download_sounds never called back")
        """)
        // Layer 3: the same-room cue (CallPlugin TriggerEvent) routes to the
        // native Soundpack's plumbing command.
        let bridged = try await host.run(
            "CallPlugin('23832d1089f727f5f34abad8', 'TriggerEvent', 'quest_target_found')"
        )
        #expect(bridged.contains(.execute("spfire quest_target_found")))
    }

    @Test("S&D's target-nearby PlaySound idiom emits a full-volume cue")
    func sndPlaySound() async throws {
        try #require(SnDFixture.install(), "S&D test fixture missing")
        let host = try SearchAndDestroyHost()
        try await host.load()
        // The exact call S&D makes (Search_and_Destroy.xml:8964): volume 100
        // is out of dB range → full volume; GetInfo(74) is the sounds dir.
        let effects = try await host.run(
            "PlaySound(0, GetInfo(74) .. 'target_nearby.wav', false, 100, 0)"
        )
        let cues = effects.compactMap { effect -> SoundCue? in
            if case .playSound(let file, let volume, let pan) = effect {
                SoundCue(file: file, volume: volume, pan: pan)
            } else { nil }
        }
        #expect(cues.count == 1)
        #expect(cues.first?.file.hasSuffix("target_nearby.wav") == true)
        #expect(cues.first?.volume == 1)
        #expect(cues.first?.pan == 0)
    }
}
