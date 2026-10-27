import Foundation
@testable import MudCore
import Testing

/// Tag-sourced events publish whether or not their line is displayed; prose
/// events publish only from displayed lines (D-128,
/// `docs/plans/S1_TAG_EVENT_SEAM_PROPOSAL.md`).
///
/// Reproduces `session-20261027-090604`: a cue set on `affect_off`, then
/// `{affoff}91` arriving hidden by a plugin's gag and by the tag-hide
/// preference. Before D-128 the session dropped the cue with the line.
/// `AudioEndToEndTests.gaggedLineProducesNoCue` keeps the prose half.
@Suite("tag events — published through the gag seam", .serialized)
struct TagEventSeamTests {
    private actor Collector {
        var files: [String] = []
        func append(_ file: String) {
            files.append(file)
        }
    }

    @Test(
        "an affect_off cue plays for {affoff}, however the line is hidden",
        arguments: [(true, true), (true, false), (false, true), (false, false)]
    )
    func tagEventCuePlays(tagHide: Bool, scriptGag: Bool) async throws {
        let engine = try ScriptEngine()
        if scriptGag {
            // The spellup plugins' idiom: match the tag line and omit it.
            try await engine.addTrigger(Trigger(pattern: .regex(#"^\{affoff\}"#), gag: true))
        }
        let conn = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { conn })
        await session.registerNativePlugin(Soundpack(configURL: nil))
        await session.setGagTagLines(tagHide)

        let cues = Collector()
        let pump = Task {
            for await cue in session.soundCues {
                await cues.append(cue.file)
            }
        }
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        try await session.send("spmute") // unmute (muted by default)
        try await session.send("spset affect_off wav spell_off.wav")
        conn.injectLine("{affoff}91")

        let played = await SessionTestSupport.poll {
            await cues.files.contains("spell_off.wav")
        }
        #expect(played, "no affect_off cue (tag hide \(tagHide), script gag \(scriptGag))")
        pump.cancel()
        await session.disconnect()
    }

    @Test("the engine holds tag-sourced effects apart from prose-sourced ones")
    func engineSplitsBySource() async throws {
        let engine = try ScriptEngine()
        // Configure through the engine: registering re-runs `install()`,
        // which re-reads config and would undo settings made before it.
        await engine.registerNativePlugin(Soundpack(configURL: nil))
        _ = await engine.expandInputForDispatch("spmute")
        _ = await engine.expandInputForDispatch("spset affect_off wav spell_off.wav")

        let tag = await engine.process(Line(id: LineID(0), text: "{affoff}91"))
        #expect(!tag.structuralEffects.isEmpty)
        #expect(tag.semanticEffects.isEmpty)

        let prose = await engine.process(Line(
            id: LineID(1),
            text: "You raise a level! You are now level 142."
        ))
        #expect(!prose.semanticEffects.isEmpty)
        #expect(prose.structuralEffects.isEmpty)
    }
}
