import Foundation
@testable import MudCore
import Testing

@Suite("Mapper custom exit regressions")
struct MapperCustomExitRegressionTests {
    private func seeded() throws -> (Mapper, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-cexit-regression-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        return (mapper, url)
    }

    private func seed(_ mapper: Mapper) async {
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"North End","zone":"z","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Middle","zone":"z","exits":{"n":3}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"South End","zone":"z","exits":{"n":2}}"#
        )
    }

    @Test("interactive cexit records the first landing, not later movement")
    func interactiveCexitCapturesFirstLanding() async throws {
        let (mapper, url) = try seeded()
        defer { try? FileManager.default.removeItem(at: url) }
        await seed(mapper) // current room = 1
        _ = await mapper.handleCommand("mapper cexit say answer;say key")

        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"First Landing","zone":"z","exits":{"n":3}}"#
        )
        // Automation may continue walking before the confirmation delay fires;
        // the custom exit itself should still point at the first landing.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Later Room","zone":"z","exits":{}}"#
        )

        let stream = await mapper.subscribeNotes()
        await mapper.finalizeCexit(generation: 1)
        var iterator = stream.makeAsyncIterator()
        let confirmation = await iterator.next()
        #expect(confirmation?.contains("(say answer;say key) -> 2") == true)
        #expect(await mapper.graph.rooms["1"]?.exits["say answer;say key"]?.to == "2")
    }
}
