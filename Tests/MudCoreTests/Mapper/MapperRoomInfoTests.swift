import Foundation
@testable import MudCore
import Testing

/// Phase 5 of the mapper-fidelity work: room info, notes & flags. The
/// `thisroom` block, the `notes` search, `addnote`/`delete note`, and the
/// `noportal`/`norecall`/`ignore mismatch` flags — checked against the reference
/// `aard_GMCP_mapper.xml`.
@Suite("Mapper — room info, notes & flags (Phase 5)")
struct MapperRoomInfoTests {
    /// Area `aylor`, rooms 1 (current, exit e→2) and 2.
    private func makeMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-roominfo-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Gate","zone":"aylor","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","terrain":"city","exits":{"e":2}}"#
        )
        return mapper
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { segs.map(\.text).joined() } else { nil }
        }
    }

    // MARK: - thisroom

    @Test("thisroom renders the reference detail block")
    func thisRoom() async throws {
        let mapper = try await makeMapper()
        let out = await notes(mapper.handleCommand("mapper thisroom"))
        #expect(out.first == "Details about this room:")
        #expect(out.contains("+---------------------------+"))
        #expect(out.contains("Name: Square"))
        #expect(out.contains("ID: 1"))
        #expect(out.contains("Area: aylor"))
        #expect(out.contains("Terrain: city"))
        #expect(out.contains("Flags:"))
        #expect(out.contains("Exits: "))
        #expect(out.contains(#""e"="2""#))
        #expect(out.contains("Ignore exits mismatch: false"))
    }

    @Test("thisroom with no current room reports the LOOK error")
    func thisRoomNoRoom() async throws {
        let mapper = try await makeMapper()
        await mapper.clearCurrentRoom()
        #expect(await notes(mapper.handleCommand("mapper thisroom")).first?
            .hasPrefix("THISROOM ERROR:") == true)
    }

    @Test("thisroom Flags line lists active noportal/norecall flags")
    func thisRoomFlags() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper noportal 1 true")
        _ = await mapper.handleCommand("mapper norecall 1 true")
        #expect(await notes(mapper.handleCommand("mapper thisroom")).contains("Flags: noportal norecall"))
    }

    // MARK: - notes search + edit

    @Test("addnote adds then changes the current room's note with reference wording")
    func addNote() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper addnote first"))
            == ["Note added to room 1 : first"])
        #expect(await notes(mapper.handleCommand("mapper addnote second"))
            == ["Note for room 1 changed to: second"])
    }

    @Test("delete note reports the previous note, or that there's none")
    func deleteNote() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper delete note")) == ["No note found here to delete."])
        _ = await mapper.handleCommand("mapper addnote keep")
        #expect(await notes(mapper.handleCommand("mapper delete note"))
            == ["Note for room 1 deleted. Was previously: keep"])
    }

    @Test("notes searches bookmarked rooms via quick_find")
    func notesSearch() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.setNote("bank here", uid: "2")
        let out = await notes(mapper.handleCommand("mapper notes"))
        #expect(out.first == "Searching all areas")
        #expect(out.contains("Found 1 target matching '[NOTE]'."))
        // Room 2 isn't the current room → a clickable row + the note as reason.
        #expect(out.contains("[1] Gate (aylor)"))
        #expect(out.contains(" -  [bank here]"))
    }

    // MARK: - flags

    @Test("noportal on a missing room reports the database error")
    func noportalMissingRoom() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper noportal 999 true"))
            == ["GMCP MAPPER NOPORTAL ERROR: Room 999 is not in the database."])
    }

    @Test("norecall set then removed reports both transitions")
    func norecallToggle() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper norecall 1 true"))
            == ["GMCP Mapper: No-recall flag set on room 1."])
        #expect(await notes(mapper.handleCommand("mapper norecall 1 false"))
            == ["GMCP Mapper: No-recall flag removed from room 1."])
        // Setting the same value again is reported as already-set.
        #expect(await notes(mapper.handleCommand("mapper norecall 1 false"))
            == ["GMCP Mapper: Room 1 already has that recall status."])
    }

    @Test("ignore mismatch defaults to the current room")
    func ignoreMismatchCurrentRoom() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper ignore mismatch true"))
            == ["Ignore exits mismatch flag set on room 1."])
        #expect(await mapper.graph.rooms["1"]?.ignoreExitsMismatch == true)
    }

    // MARK: - exit carry-forward on revisit (hidden cardinals + custom)

    /// A hidden compass exit (a secret `down` GMCP never lists) must survive a
    /// revisit whose `room.info` omits it — the reference's `save_room_exits`
    /// only upserts and never prunes. Without the carry-forward, `saveExits`
    /// delete-then-inserts the GMCP-only set and the hidden `d` is lost,
    /// stranding whatever it reaches. Fails before the `mergedExits` fix.
    @Test("hidden cardinal exit survives a revisit that omits it (in-memory + persisted)")
    func hiddenCardinalCarriedForward() async throws {
        let mapper = try await makeMapper()
        // Teach a hidden d→3 from room 1 (room 3's GMCP never advertises the up link's twin).
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Cellar","zone":"aylor","exits":{"u":1}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","terrain":"city","exits":{"e":2,"d":3}}"#
        )
        #expect(await mapper.graph.rooms["1"]?.exits["d"]?.to == "3")

        // Revisit room 1; GMCP omits the hidden `d` (it isn't an advertised exit).
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","terrain":"city","exits":{"e":2}}"#
        )
        #expect(await mapper.graph.rooms["1"]?.exits["d"]?.to == "3")

        // And it persisted (survives a reload from the store, not just in memory).
        try await mapper.reload()
        #expect(await mapper.graph.rooms["1"]?.exits["d"]?.to == "3")
    }

    /// The route to a room reachable only via a hidden exit must still exist
    /// after that exit's source room is revisited — the Zangar-island case.
    @Test("pathfinder still routes through a hidden exit after a revisit")
    func hiddenExitStaysReachableAfterRevisit() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Cellar","zone":"aylor","exits":{"u":1}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","terrain":"city","exits":{"e":2,"d":3}}"#
        )
        // Revisit room 1 without the hidden `d` exit.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","terrain":"city","exits":{"e":2}}"#
        )
        let route = await Pathfinder(graph: mapper.graph).path(from: "1", to: "3")
        #expect(route == [PathStep(dir: "d", uid: "3")])
    }

    /// GMCP still wins for a direction it *does* report: a changed destination
    /// replaces the old one (no stale duplicate, no count growth).
    @Test("GMCP replaces a changed destination for a reported direction")
    func gmcpReplacesChangedDestination() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","terrain":"city","exits":{"e":9}}"#
        )
        #expect(await mapper.graph.rooms["1"]?.exits["e"]?.to == "9")
        #expect(await mapper.graph.rooms["1"]?.exits.count == 1)
    }

    /// Regression guard: custom-command exits were already carried forward; the
    /// hidden-cardinal fix must not change that.
    @Test("custom-command exit survives a revisit (regression)")
    func customExitCarriedForward() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullcexit {enter gate} 1 2 0")
        #expect(await mapper.graph.rooms["1"]?.exits["enter gate"]?.to == "2")
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","terrain":"city","exits":{"e":2}}"#
        )
        #expect(await mapper.graph.rooms["1"]?.exits["enter gate"]?.to == "2")
    }
}
