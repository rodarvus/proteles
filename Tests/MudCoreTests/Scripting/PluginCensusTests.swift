import Foundation
@testable import MudCore
import Testing

/// #63 diagnostics: the per-plugin rule census and the unconditional
/// script-error transcript write — the two probes that make an "env alive,
/// rules dead" session diagnosable from its transcript alone.
@Suite("Plugin diagnostics (#63)")
struct PluginCensusTests {
    @Test("ruleCensus counts XML-declared and dynamically-added rules, with enabled split")
    func censusCounts() async throws {
        let engine = try ScriptEngine()
        let plugin = MUSHclientPlugin(
            id: "censusplugin",
            name: "Census",
            script: """
            -- A dynamic registration alongside the XML ones.
            AddAlias("dyn_alias", "^dynalias$", "say hi", 0, "")
            """,
            triggers: [
                Trigger(pattern: .substring("alpha")),
                Trigger(pattern: .substring("beta"), enabled: false),
                Trigger(pattern: .substring("gamma"))
            ],
            aliases: [
                Alias(pattern: .exact("go"))
            ],
            timers: [
                MudTimer(schedule: .every(30), action: .send("tick"))
            ]
        )
        _ = await engine.loadPlugin(plugin)

        let census = await engine.ruleCensus(forPlugin: "censusplugin")
        #expect(census.triggers == 3)
        #expect(census.enabledTriggers == 2)
        #expect(census.aliases == 2) // 1 XML + 1 AddAlias from the script
        #expect(census.timers == 1)

        // Another plugin's rules never leak into this census.
        #expect(await engine.ruleCensus(forPlugin: "someoneelse") == .init(
            triggers: 0, enabledTriggers: 0, aliases: 0, enabledAliases: 0, timers: 0
        ))

        // The summary is the transcript payload.
        #expect(census.summary.contains("3 triggers (2 enabled)"))
        #expect(census.summary.contains("1 timer"))
    }

    @Test("script errors reach the transcript even when #16 routes notes console-only")
    func scriptErrorAlwaysInTranscript() async throws {
        let engine = try ScriptEngine()
        let session = SessionController(
            scriptEngine: engine, makeConnection: { InMemoryConnection() }
        )
        // The #16 console-only routing: red notes suppressed.
        await session.setScriptErrorsInOutput(false)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("census-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordingURL = dir.appendingPathComponent("session.jsonl")
        try await session.startRecording(to: recordingURL)

        await session.applyScriptEffects([
            .diagnostic(source: "broken-plugin", message: "attempt to index a nil value")
        ])
        await session.stopRecording()

        let transcriptURL = SessionTranscript.url(pairedWith: recordingURL)
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(transcript.contains("[script-error: broken-plugin] attempt to index a nil value"))
    }
}
