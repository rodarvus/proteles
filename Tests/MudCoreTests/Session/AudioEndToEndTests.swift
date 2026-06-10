import Foundation
@testable import MudCore
import Testing

/// The audio pipelines (#10 sound, #9 speech) driven through the REAL
/// session: wire-framed GMCP / inbound lines on an `InMemoryConnection`,
/// the app-shaped native registration, and the published streams the app's
/// players consume.
@Suite("audio — end-to-end through the session", .serialized)
struct AudioEndToEndTests {
    private func gmcpBytes(_ payload: String) -> [UInt8] {
        [255, 250, 201] + Array(payload.utf8) + [255, 240]
    }

    private func poll(_ check: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await check()
    }

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
        conn.injectInbound(gmcpBytes(
            #"comm.channel {"chan":"tell","msg":"Eketra tells you 'hi'","player":"Eketra"}"#
        ))
        let played = await poll {
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
        let played = await poll {
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
        let spoke = await poll {
            await requests.values.contains {
                $0 == .speak(text: "The Grand City of Aylor stretches before you.", interrupt: false)
            }
        }
        #expect(spoke, "the displayed line was never spoken")

        // A gagged line (ChatEcho's inline channel dupe) must NOT speak.
        conn.injectInbound(gmcpBytes(
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
        let stopped = await poll { await requests.values.contains(.stop) }
        #expect(stopped, "tts stop never reached the stream")
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
        let buffered = await poll {
            await session.scrollbackStore.snapshot().count >= 2
        }
        #expect(buffered)
        try await session.send("tts last 2")
        let reread = await poll {
            await requests.values.contains { $0 == .speak(text: "Second line of prose.", interrupt: false) }
        }
        #expect(reread, "tts last never re-read the buffer")
        pump.cancel()
        await session.disconnect()
    }
}
