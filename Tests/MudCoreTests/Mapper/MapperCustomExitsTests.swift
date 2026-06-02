import Foundation
@testable import MudCore
import Testing

/// Phase 4 of the mapper-fidelity work: custom exits. The `cexits` table, the
/// `fullcexit` create messages, `delete cexits`, `cexit_wait`, and the
/// `purge cexits [area]` confirm step — checked against the reference
/// `aard_GMCP_mapper.xml` (`custom_exit_list`/`custom_fullexit`/
/// `map_cexits_delete`/`change_cexit_delay`/`map_cexits_purge`).
@Suite("Mapper — custom exits (Phase 4)")
struct MapperCustomExitsTests {
    /// Area `aylor`, rooms 1 (current) and 2.
    private func makeMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-cexits-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Gate","zone":"aylor","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","exits":{}}"#
        )
        return mapper
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { segs.map(\.text).joined() } else { nil }
        }
    }

    private func firstSegment(_ effect: ScriptEffect) -> NoteSegment? {
        if case .colourNote(let segs) = effect { segs.first } else { nil }
    }

    private let border = "+------------+----------------------+---------+----------------------+---------+"
    private let header = "| area       | room name            |  rm uid | dir                  |  to uid |"

    // MARK: - fullcexit + cexits table

    @Test("fullcexit confirms with the reference message + lock level")
    func fullcexitConfirm() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper fullcexit {enter gate} 1 2 5"))
            == ["Custom Exit CONFIRMED: 1 (enter gate) -> 2 [lock level 5]"])
    }

    @Test("fullcexit to an unknown room fails with the reference message")
    func fullcexitUnknownRoom() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper fullcexit {enter gate} 1 999"))
            == ["CEXIT FAILED: Room 999 is unknown."])
    }

    @Test("cexits renders the bordered, clickable table")
    func cexitsTable() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullcexit {enter gate} 1 2 0")
        let effects = await mapper.handleCommand("mapper cexits")
        let out = notes(effects)
        #expect(out.contains(border))
        #expect(out.contains(header))
        // The data row, field-formatted per the reference fmt.
        #expect(out
            .contains("| aylor      | Square               |       1 | enter gate           |       2 |"))
        #expect(out.contains("Found 1 custom exits."))
        // The row is clickable to the source room.
        #expect(effects.contains { firstSegment($0)?.link?.action == .sendCommand("mapper goto 1") })
    }

    @Test("cexits thisroom scopes to the current room")
    func cexitsThisRoom() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullcexit {enter gate} 1 2 0")
        #expect(await notes(mapper.handleCommand("mapper cexits thisroom"))
            .contains("The following custom exits are in this room:"))
    }

    // MARK: - delete cexits

    @Test("delete cexits reports each then removes them")
    func deleteCexits() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullcexit {enter gate} 1 2 0")
        let out = await notes(mapper.handleCommand("mapper delete cexits"))
        #expect(out.contains(#"Found custom exit "enter gate" to room 2 "Gate""#))
        #expect(out.contains("Removed custom exits from the current room."))
        #expect(await notes(mapper.handleCommand("mapper cexits")).contains("Found 0 custom exits."))
    }

    // MARK: - cexit_wait

    @Test("cexit_wait sets the next cexit delay within range")
    func cexitWaitValid() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper cexit_wait 8"))
            == ["CEXIT_DELAY: The next mapper custom exit will have 8 seconds to complete."])
    }

    @Test("cexit_wait rejects an out-of-range delay and falls back to the base")
    func cexitWaitInvalid() async throws {
        let mapper = try await makeMapper()
        let out = await notes(mapper.handleCommand("mapper cexit_wait 99"))
        #expect(out.contains("CEXIT_DELAY FAILED: Invalid delay given (99). Must be a number from 2 to 40."))
        #expect(out.contains("CEXIT_DELAY: The next mapper custom exit will have 2 seconds to complete."))
    }

    // MARK: - purge cexits confirm

    @Test("purge cexits arms a confirm, and confirm clears them")
    func purgeCexitsConfirm() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullcexit {enter gate} 1 2 0")
        #expect(await notes(mapper.handleCommand("mapper purge cexits")) == [
            "Are you sure you want to purge all custom mapper exits? "
                + "To confirm type 'mapper purge cexits confirm'."
        ])
        #expect(await notes(mapper.handleCommand("mapper purge cexits confirm"))
            == ["Purged all custom exits."])
        #expect(await notes(mapper.handleCommand("mapper cexits")).contains("Found 0 custom exits."))
    }

    @Test("purge cexits area arms its own confirm")
    func purgeCexitsAreaConfirm() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper purge cexits area")) == [
            "Are you sure you want to purge all custom mapper exits in this area? "
                + "To confirm type 'mapper purge cexits area confirm'."
        ])
        #expect(await notes(mapper.handleCommand("mapper purge cexits area confirm"))
            == ["Purged all area custom exits."])
    }
}
