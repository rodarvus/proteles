import Foundation
@testable import MudCore
import Testing

/// The fix for the F9/F10/F11 race: a macro `mapper goto X` ⏎ `quest …` must run
/// the follow-up AFTER arrival, not race the walk. Live (`session-20260619-104106`)
/// `quest complete` hit the wire ~1s early, at "Union Station", and the server
/// replied "You need to be at a questmaster". These drive the REAL SessionController
/// + Mapper + InMemoryConnection and assert the follow-up is held until the
/// destination `room.info` lands.
@Suite("SessionController — walk deferral", .serialized)
struct WalkDeferralTests {
    /// Linear map 1 —e→ 2 —e→ 3, standing in room 1. A `goto 3` speedwalks
    /// `run 2e` and lands in 3.
    private func makeMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walkdefer-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"z","name":"Z"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"One","zone":"z","exits":{"e":2}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Two","zone":"z","exits":{"e":3,"w":1}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Three","zone":"z","exits":{"w":2}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"One","zone":"z","exits":{"e":2}}"#
        )
        return mapper
    }

    private func makeSession(_ mapper: Mapper) async throws -> (SessionController, InMemoryConnection) {
        let engine = try ScriptEngine()
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        await controller.attachMapper(mapper)
        try await controller.connect(to: .init(host: "test.invalid", port: 23))
        return (controller, conn)
    }

    private func arrive(_ controller: SessionController, num: Int, exits: String) async {
        await controller.dispatchGMCP(GMCPMessage(
            package: "room.info",
            json: #"{"num":\#(num),"name":"R","zone":"z","exits":{\#(exits)}}"#
        ))
    }

    @Test("a macro's follow-up command waits for arrival, not the goto")
    func followUpHeldUntilArrival() async throws {
        let mapper = try await makeMapper()
        let (controller, conn) = try await makeSession(mapper)
        defer { Task { await controller.disconnect() } }

        // F10-shaped macro: goto then a questmaster command.
        await controller.fire(.command("mapper goto 3\nquest complete"))

        // The walk started, but the follow-up must NOT be on the wire yet.
        #expect(conn.sentLines.contains("run 2e"))
        #expect(conn.sentLines.contains("quest complete") == false)

        // An intermediate room must NOT release it (the gate is the final target).
        await arrive(controller, num: 2, exits: #""e":3,"w":1"#)
        #expect(conn.sentLines.contains("quest complete") == false)

        // Arriving at the destination releases it.
        await arrive(controller, num: 3, exits: #""w":2"#)
        #expect(conn.sentLines.contains("quest complete"))
        // And it ran strictly after the movement.
        let lines = conn.sentLines
        let questIndex = try #require(lines.firstIndex(of: "quest complete"))
        let runIndex = try #require(lines.firstIndex(of: "run 2e"))
        #expect(questIndex > runIndex)
    }

    @Test("a new goto supersedes — the earlier held follow-up is dropped")
    func newGotoDropsHeldFollowUp() async throws {
        let mapper = try await makeMapper()
        let (controller, conn) = try await makeSession(mapper)
        defer { Task { await controller.disconnect() } }

        await controller.fire(.command("mapper goto 3\nquest complete"))
        // Redirect before arriving: a second goto with a different follow-up.
        await controller.fire(.command("mapper goto 3\ncp request"))

        await arrive(controller, num: 3, exits: #""w":2"#)

        #expect(conn.sentLines.contains("cp request"))
        #expect(conn.sentLines.contains("quest complete") == false)
    }

    @Test("already at the target runs the follow-up immediately (no walk)")
    func alreadyThereRunsImmediately() async throws {
        let mapper = try await makeMapper()
        // Stand in room 3 so `goto 3` is a no-op walk.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Three","zone":"z","exits":{"w":2}}"#
        )
        let (controller, conn) = try await makeSession(mapper)
        defer { Task { await controller.disconnect() } }

        await controller.fire(.command("mapper goto 3\nquest complete"))
        // No walk armed → the follow-up went straight to the wire.
        #expect(conn.sentLines.contains("quest complete"))
    }
}
