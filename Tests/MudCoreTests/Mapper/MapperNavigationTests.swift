import Foundation
@testable import MudCore
import Testing

/// Phase 1 of the mapper-fidelity work: navigation & path commands — `where` /
/// `findpath` in the reference `printpath` format, `goto`/`walkto` error wording,
/// and `resume` / `stop` / `next`. Strings checked verbatim against
/// `aard_GMCP_mapper.xml` (`map_where` / `printpath` / `cancel_speedwalk` /
/// `do_next`).
@Suite("Mapper — navigation & path (Phase 1)")
struct MapperNavigationTests {
    /// A tiny linear map: 1 —e→ 2 —e→ 3, all in one area, so a known-shape
    /// speedwalk falls out.
    private func makeMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-nav-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"One","zone":"aylor","exits":{"e":2}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Two","zone":"aylor","exits":{"e":3,"w":1}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Three","zone":"aylor","exits":{"w":2}}"#
        )
        return mapper
    }

    /// Re-ingest room 1's `room.info` so the mapper considers room 1 the current
    /// room (the last ingested room becomes `currentRoomUID`).
    private func standInRoomOne(_ mapper: Mapper) async {
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"One","zone":"aylor","exits":{"e":2}}"#
        )
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { segs.map(\.text).joined() } else { nil }
        }
    }

    // MARK: - goto / walkto wording

    @Test("goto/walkto with no argument use the reference room-id wording")
    func gotoWalktoNoArg() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper goto"))
            == ["The mapper goto command expects a room id as input."])
        #expect(await notes(mapper.handleCommand("mapper walkto"))
            == ["The mapper walkto command expects a room id as input."])
    }

    // MARK: - where (printpath)

    @Test("where with no current room reports the LOOK hint")
    func whereNoCurrentRoom() async throws {
        let mapper = try await makeMapper()
        await mapper.clearCurrentRoom()
        #expect(await notes(mapper.handleCommand("mapper where 3"))
            == ["I don't know where you are right now - try: LOOK"])
    }

    @Test("where to the current room is rejected")
    func whereSameRoom() async throws {
        let mapper = try await makeMapper()
        await standInRoomOne(mapper)
        #expect(await notes(mapper.handleCommand("mapper where 1"))
            == ["You are already in that room."])
    }

    @Test("where prints the printpath format: header / speedwalk / distance / blank")
    func wherePrintpath() async throws {
        let mapper = try await makeMapper()
        await standInRoomOne(mapper)
        let out = await notes(mapper.handleCommand("mapper where 3"))
        // From the current room → "Path to <dest> is:" header.
        #expect(out.first == "Path to 3 is:")
        #expect(out.contains("Distance: 2"))
        #expect(out.last?.isEmpty == true)
        // The speedwalk run is spaced out for screen readers (gsub "%a","%1 ").
        #expect(out[1] == "run 2e")
    }

    // MARK: - findpath (printpath between two rooms)

    @Test("findpath between two rooms prints the from→to printpath")
    func findpathTwoRooms() async throws {
        let mapper = try await makeMapper()
        let out = await notes(mapper.handleCommand("mapper findpath 1 3"))
        #expect(out.first == "Path from 1 to 3 is:")
        #expect(out.contains("Distance: 2"))
        #expect(out[1] == "run 2e")
    }

    @Test("findpath with one argument reports the two-id usage")
    func findpathOneArg() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper findpath 1"))
            == ["The mapper findpath command expects two room ids as input."])
    }

    @Test("findpath to an unknown room reports it not known")
    func findpathUnknownRoom() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper findpath 1 999"))
            == ["Room 999 not known."])
    }

    // MARK: - resume / stop / next (empty state)

    @Test("resume with nothing pending reports no outstanding speedwalks")
    func resumeEmpty() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper resume"))
            == ["No outstanding speedwalks or hyperlinks."])
    }

    @Test("stop with nothing pending is silent")
    func stopEmpty() async throws {
        let mapper = try await makeMapper()
        #expect(await mapper.handleCommand("mapper stop").isEmpty)
    }

    @Test("next with no prior search reports no more results")
    func nextEmpty() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper next"))
            == ["NEXT ERROR: No more NEXT results left."])
    }

    @Test("next #n out of range reports there is no such result")
    func nextOutOfRange() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper next 5"))
            == ["NEXT ERROR: There is no NEXT result #5."])
    }
}
