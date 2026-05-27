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
