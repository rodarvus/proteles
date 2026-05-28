import Foundation
@testable import MudCore
import Testing

@Suite("SessionController — Search-and-Destroy wiring (S6.3)")
struct SessionControllerSearchAndDestroyTests {
    init() {
        SnDFixture.install()
    }

    @Test("A published model effect is forwarded to the publishedModels stream")
    func forwardsPublishedModel() async {
        let session = SessionController()
        var iterator = session.publishedModels.makeAsyncIterator()
        let json = #"{"activity":"cp","targets":[]}"#
        await session.applyScriptEffects([.publishModel(json)])
        let received = await iterator.next()
        #expect(received == json)
    }

    @Test("S&D commands are intercepted; other input is not")
    func interceptsCommands() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        let session = SessionController()
        await session.attachSearchAndDestroy(host)

        // "xcp" is an S&D alias → handled here, not sent verbatim.
        #expect(await session.handleSearchAndDestroyCommand("xcp"))
        // A plain sentence isn't an S&D command → falls through.
        #expect(await session.handleSearchAndDestroyCommand("look at the fountain") == false)
    }

    @Test("Re-attach replays the GMCP snapshot so xcp isn't stuck in 'unknown state'")
    func reattachReplaysGMCPSnapshot() async throws {
        // A host re-created mid-session (DB import / plugin change) starts blank,
        // and Aardwolf only re-sends char.status on a state change — so without
        // a replay the character reads "unknown state" and xcp refuses to run.
        let host = try SearchAndDestroyHost()
        try await host.load()
        let session = SessionController()
        // The session saw live GMCP before the re-attach (cached by dispatchGMCP).
        await session.dispatchGMCP(GMCPMessage(
            package: "char.status", json: #"{"level":201,"state":3,"pos":"Standing"}"#
        ))
        await session.dispatchGMCP(GMCPMessage(package: "char.base", json: #"{"tier":"0"}"#))
        // A freshly loaded host has no character state yet → not ready.
        #expect(await host.evaluate("tostring(is_character_ready())") == "false")

        await session.replayGMCPSnapshot(to: host)

        // After the replay it has a ready character, so xcp won't bail out.
        #expect(await host.evaluate("tostring(is_character_ready())") == "true")
        #expect(await host.evaluate(#"gmcp("char.status.state")"#) == "3")
    }

    @Test("Feeding lines through an attached host is well-behaved")
    func processesLines() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        let session = SessionController()
        await session.attachSearchAndDestroy(host)
        // Drive a line through the scripting path — must not crash with no
        // script engine and no connection.
        await session.appendLineThroughScripts(Line(id: LineID(1), text: "You receive 5 experience points."))
    }
}
