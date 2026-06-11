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
        _ = await engine.registerNativePlugin(Soundpack(configURL: nil))
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })

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
        _ = await engine.registerNativePlugin(Soundpack(configURL: nil))
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })

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
        _ = await engine.registerNativePlugin(ChatEcho()) // gags inline channel dupes
        _ = await engine.registerNativePlugin(TextToSpeech(configURL: nil))
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })

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

    @Test("an unchanged prompt re-sent in sequence speaks once (live report)")
    func promptDedup() async throws {
        let engine = try ScriptEngine()
        _ = await engine.registerNativePlugin(TextToSpeech(configURL: nil))
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("tts on")
        let prompt = "1234hp 567mn 890mv>"
        conn.injectLine(prompt)
        conn.injectLine(prompt)
        conn.injectLine(prompt)
        conn.injectLine("You sit down and rest.")
        conn.injectLine(prompt)
        let settled = await SessionTestSupport.poll {
            let values = await requests.values
            return values.contains { $0 == .speak(text: prompt, interrupt: false) }
                && values.contains { $0 == .speak(text: "You sit down and rest.", interrupt: false) }
        }
        #expect(settled)
        try? await Task.sleep(for: .milliseconds(100))
        let promptSpeaks = await requests.values.count(where: {
            $0 == .speak(text: prompt, interrupt: false)
        })
        // Three identical in a row collapse to one; the re-send after a
        // different line speaks again.
        #expect(promptSpeaks == 2, "expected 2 prompt utterances, got \(promptSpeaks)")
        pump.cancel()
        await session.disconnect()
    }

    @Test("turning speech off via .setSpeechMode flushes the queue (Settings path)")
    func settingsOffFlushes() async throws {
        let engine = try ScriptEngine()
        _ = await engine.registerNativePlugin(TextToSpeech(configURL: nil))
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })

        let requests = Collector<SpeechRequest>()
        let pump = Task {
            for await request in session.speechRequests {
                await requests.append(request)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("tts on")
        // The Settings ▸ Audio path reaches the session as a bare mode change
        // (plugin reload → install → .setSpeechMode), with no explicit
        // `tts off` — it must still stop the babbling backlog.
        _ = await session.applySpeechEffect(.setSpeechMode(.off))
        let stopped = await SessionTestSupport.poll { await requests.values.contains(.stop) }
        #expect(stopped, "mode .off never flushed the speech queue")
        pump.cancel()
        await session.disconnect()
    }

    @Test("tts last re-reads recent displayed output, newest batch in order")
    func speakLast() async throws {
        let engine = try ScriptEngine()
        _ = await engine.registerNativePlugin(TextToSpeech(configURL: nil))
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })

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
