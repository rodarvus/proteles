import Foundation
@testable import MudCore
import Testing

/// The audio pipelines (#10 sound, #9 speech) driven through the REAL
/// session: wire-framed GMCP / inbound lines on an `InMemoryConnection`,
/// the app-shaped native registration, and the published streams the app's
/// players consume.
@Suite("audio — end-to-end through the session", .serialized)
struct AudioEndToEndTests {
    /// An actor collecting stream values so polls can read them safely.
    private actor Collector<Value: Sendable> {
        var values: [Value] = []
        func append(_ value: Value) {
            values.append(value)
        }
    }

    @Test("comm.channel GMCP → a .playSound cue on the session's sound stream")
    func channelSoundCue() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(Soundpack(configURL: nil))

        let cues = Collector<SoundCue>()
        let pump = Task {
            for await cue in session.soundCues {
                await cues.append(cue)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("spmute") // unmute (muted by default)
        conn.injectInbound(SessionTestSupport.gmcpBytes(
            #"comm.channel {"chan":"tell","msg":"Eketra tells you 'hi'","player":"Eketra"}"#
        ))
        let played = await SessionTestSupport.poll {
            await cues.values.contains { $0.file == "tell.wav" && $0.volume == 1 }
        }
        #expect(played, "the tell channel never produced its cue")
        pump.cancel()
        await session.disconnect()
    }

    @Test("a level-up line through the pipeline plays level_up.wav")
    func lineSoundCue() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(Soundpack(configURL: nil))

        let cues = Collector<SoundCue>()
        let pump = Task {
            for await cue in session.soundCues {
                await cues.append(cue)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("spmute") // unmute (muted by default)
        conn.injectLine("You raise a level! You are now level 142.")
        let played = await SessionTestSupport.poll {
            await cues.values.contains { $0.file == "level_up.wav" }
        }
        #expect(played, "the level-up line never produced its cue")
        pump.cancel()
        await session.disconnect()
    }

    @Test("tts on speaks displayed lines; gagged lines stay silent; tts stop flushes")
    func speechPipeline() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(ChatEcho()) // gags inline channel dupes
        await session.registerNativePlugin(TextToSpeech(configURL: nil))

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("tts on") // the plugin consumes it
        conn.injectLine("The Grand City of Aylor stretches before you.")
        let spoke = await SessionTestSupport.poll {
            await requests.values.contains {
                $0 == .speak(text: "The Grand City of Aylor stretches before you.", interrupt: false)
            }
        }
        #expect(spoke, "the displayed line was never spoken")

        // A gagged line (ChatEcho's inline channel dupe) must NOT speak.
        conn.injectInbound(SessionTestSupport.gmcpBytes(
            #"comm.channel {"chan":"gossip","msg":"Eketra gossips 'spam'","player":"Eketra"}"#
        ))
        conn.injectLine("Eketra gossips 'spam'")
        try? await Task.sleep(for: .milliseconds(200))
        let spokenTexts = await requests.values.compactMap { request -> String? in
            if case .speak(let text, _) = request { return text } else { return nil }
        }
        // The GMCP echo line displays (and may speak); the raw inline dupe is
        // gagged. At most one spoken copy, never two.
        #expect(spokenTexts.count(where: { $0.contains("spam") }) <= 1, "the gagged dupe spoke too")

        try await session.send("tts stop")
        let stopped = await SessionTestSupport.poll { await requests.values.contains(.stop) }
        #expect(stopped, "tts stop never reached the stream")
        pump.cancel()
        await session.disconnect()
    }

    @Test("prompts: silent by default (canon); delta mode speaks only changes, movement never")
    func promptSpeech() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(TextToSpeech(configURL: nil))

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("tts on")
        // Default (community canon): prompts say NOTHING, even with changes.
        conn.injectLine("999/1234hp 500/567mn 890/1000mv>")
        conn.injectLine("Prompts default to silence.")
        let defaulted = await SessionTestSupport.poll {
            await requests.values.contains {
                $0 == .speak(text: "Prompts default to silence.", interrupt: false)
            }
        }
        #expect(defaulted)
        // Opt in to the delta mode, then walk/rest/damage/cast.
        try await session.send("tts prompts delta")
        conn.injectLine("1234/1234hp 567/567mn 890/1000mv>") // first prompt → baseline
        conn.injectLine("1234/1234hp 567/567mn 890/1000mv>") // identical → silent
        conn.injectLine("1234/1234hp 567/567mn 850/1000mv>") // walking: mv only → silent
        conn.injectLine("You sit down and rest.")
        conn.injectLine("1234/1234hp 567/567mn 850/1000mv>") // still unchanged → silent
        conn.injectLine("1100/1234hp 567/567mn 850/1000mv>") // took damage → hp only
        conn.injectLine("1100/1234hp 520/567mn 850/1000mv>") // cast → mana only
        let settled = await SessionTestSupport.poll {
            await requests.values.contains { $0 == .speak(text: "mana 520", interrupt: false) }
        }
        #expect(settled)
        let spoken = await requests.values.compactMap { request -> String? in
            if case .speak(let text, _) = request { return text } else { return nil }
        }
        #expect(spoken == [
            "Text to speech on", // the tts on confirmation utterance
            "Prompts default to silence.", // the silent-prompt prose marker
            "hp 1234, mana 567", // delta mode: baseline orients once
            "You sit down and rest.",
            "hp 1100", // damage says only hp
            "mana 520" // casting says only mana
        ], "unexpected spoken sequence: \(spoken)")
        pump.cancel()
        await session.disconnect()
    }

    @Test("typed commands cut stale speech; tts enter turns that off")
    func enterInterrupts() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(TextToSpeech(configURL: nil))

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("tts on")
        try await session.send("look") // typed command → .stop precedes it
        let stopped = await SessionTestSupport.poll { await requests.values.contains(.stop) }
        #expect(stopped, "a typed command never cut stale speech")

        try await session.send("tts enter") // toggle the canon behaviour off
        let baseline = await requests.values.count(where: { $0 == .stop })
        try await session.send("look")
        try? await Task.sleep(for: .milliseconds(100))
        let after = await requests.values.count(where: { $0 == .stop })
        #expect(after == baseline, "enter still interrupted after tts enter off")
        pump.cancel()
        await session.disconnect()
    }

    @Test("tts mute: a muted channel's line displays but never speaks; review honors subst")
    func channelSpeechMuteAndReview() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(TextToSpeech(configURL: nil))

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("tts on")
        try await session.send("tts mute gossip")
        // The channel arrives as GMCP (captured + remembered) AND as the
        // inline display line — the muted channel's line must not speak.
        conn.injectInbound(SessionTestSupport.gmcpBytes(
            #"comm.channel {"chan":"gossip","msg":"Eketra gossips 'big spam'","player":"Eketra"}"#
        ))
        conn.injectLine("Eketra gossips 'big spam'")
        conn.injectLine("A quiet room.")
        let settled = await SessionTestSupport.poll {
            await requests.values.contains { $0 == .speak(text: "A quiet room.", interrupt: false) }
        }
        #expect(settled)
        let spokeGossip = await requests.values.contains {
            if case .speak(let text, _) = $0 { text.contains("big spam") } else { false }
        }
        #expect(!spokeGossip, "a speech-muted channel line was spoken")
        // The line still displayed (speech-gag ≠ display-gag).
        let displayed = await session.scrollbackStore.snapshot()
            .contains { $0.text.contains("big spam") }
        #expect(displayed, "the muted channel line should still display")

        // tts review replays the captured chat for the muted channel too —
        // muting live speech doesn't hide history (review is explicit).
        try await session.send("tts review gossip 1")
        let reviewed = await SessionTestSupport.poll {
            await requests.values.contains {
                if case .speak(let text, true) = $0 { text.contains("big spam") } else { false }
            }
        }
        #expect(reviewed, "tts review never replayed the captured channel line")
        pump.cancel()
        await session.disconnect()
    }

    @Test("!skip substitution speech-gags a line that still displays")
    func skipSubstitution() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(TextToSpeech(configURL: nil))

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("tts on")
        try await session.send("tts subst add utters the words==!skip")
        try await session.send("tts subst add Aylor==ay lor")
        conn.injectLine("Eketra utters the words, 'judicandus'.") // spellcast spam → skipped
        conn.injectLine("Welcome to Aylor!") // pronunciation fix applies
        let settled = await SessionTestSupport.poll {
            await requests.values.contains { $0 == .speak(text: "Welcome to ay lor!", interrupt: false) }
        }
        #expect(settled, "the pronunciation fix never applied")
        let spokeSkipped = await requests.values.contains {
            if case .speak(let text, _) = $0 { text.contains("judicandus") } else { false }
        }
        #expect(!spokeSkipped, "a !skip line was spoken")
        let displayed = await session.scrollbackStore.snapshot()
            .contains { $0.text.contains("judicandus") }
        #expect(displayed, "the !skip line should still display")
        pump.cancel()
        await session.disconnect()
    }

    @Test("the soundpack mute gates S&D-style direct cues; confirmation order holds")
    func muteGatesAllCues() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(Soundpack(configURL: nil))

        let cues = Collector<SoundCue>()
        let pump = Task {
            for await cue in session.soundCues {
                await cues.append(cue)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        // Muted by default: a direct .playSound (S&D's PlaySound path) is gated.
        await session.applyScriptEffects([.playSound(file: "target_nearby.wav", volume: 1, pan: 0)])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await cues.values.isEmpty, "a direct cue escaped the default mute")

        // Unmute → the same cue plays; the spmute confirmation also played.
        try await session.send("spmute")
        await session.applyScriptEffects([.playSound(file: "target_nearby.wav", volume: 1, pan: 0)])
        let played = await SessionTestSupport.poll {
            await cues.values.contains { $0.file == "target_nearby.wav" }
        }
        #expect(played)
        #expect(await cues.values.contains { $0.file == "channel_on.wav" }, "no unmute confirmation")

        // Re-mute: the confirmation cue still sounds (ordered before the
        // gate closes — the reference plays feedback on disable too), but
        // nothing after it does.
        let beforeMute = await cues.values.count
        try await session.send("spmute")
        try? await Task.sleep(for: .milliseconds(150))
        let afterMute = await cues.values
        #expect(afterMute.count == beforeMute + 1, "expected exactly the disable confirmation")
        #expect(afterMute.last?.file == "channel_on.wav")
        await session.applyScriptEffects([.playSound(file: "target_nearby.wav", volume: 1, pan: 0)])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await cues.values.count == afterMute.count, "a cue escaped after re-mute")
        pump.cancel()
        await session.disconnect()
    }

    @Test("tts vitals speaks the GMCP stats on demand")
    func vitalsOnDemand() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(TextToSpeech(configURL: nil))

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        conn.injectInbound(SessionTestSupport.gmcpBytes(
            #"char.vitals {"hp":1180,"mana":600,"moves":950}"#
        ))
        conn.injectInbound(SessionTestSupport.gmcpBytes(
            #"char.maxstats {"maxhp":1234,"maxmana":700,"maxmoves":1000}"#
        ))
        try? await Task.sleep(for: .milliseconds(100))
        try await session.send("tts vitals")
        let spoke = await SessionTestSupport.poll {
            await requests.values.contains {
                $0 == .speak(
                    text: "hp 1180 of 1234, mana 600 of 700, moves 950 of 1000",
                    interrupt: true
                )
            }
        }
        #expect(spoke, "tts vitals never spoke the cached stats")
        pump.cancel()
        await session.disconnect()
    }

    @Test("turning speech off via .setSpeechPolicy flushes the queue (Settings path)")
    func settingsOffFlushes() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(TextToSpeech(configURL: nil))

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("tts on")
        // The Settings ▸ Audio path reaches the session as a bare mode change
        // (plugin reload → install → .setSpeechPolicy), with no explicit
        // `tts off` — it must still stop the babbling backlog.
        _ = await session.applySpeechEffect(.setSpeechPolicy(SpeechPolicy(mode: .off)))
        let stopped = await SessionTestSupport.poll { await requests.values.contains(.stop) }
        #expect(stopped, "mode .off never flushed the speech queue")
        pump.cancel()
        await session.disconnect()
    }

    @Test("tts last re-reads recent displayed output, newest batch in order")
    func speakLast() async throws {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(TextToSpeech(configURL: nil))

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        conn.injectLine("First line of prose.")
        conn.injectLine("Second line of prose.")
        let buffered = await SessionTestSupport.poll {
            await session.scrollbackStore.snapshot().count >= 2
        }
        #expect(buffered)
        try await session.send("tts last 2")
        let reread = await SessionTestSupport.poll {
            await requests.values.contains { $0 == .speak(text: "Second line of prose.", interrupt: false) }
        }
        #expect(reread, "tts last never re-read the buffer")
        pump.cancel()
        await session.disconnect()
    }
}
