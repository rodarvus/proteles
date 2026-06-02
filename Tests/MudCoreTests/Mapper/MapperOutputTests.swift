import Foundation
@testable import MudCore
import Testing

/// Phase 0 of the mapper-fidelity work: the shared output layer + the first
/// table command (`mapper areas`) rendered byte-faithfully to the reference
/// (`aard_GMCP_mapper.xml` `map_areas`).
@Suite("Mapper — faithful output layer (Phase 0)")
struct MapperOutputTests {
    // MARK: - Primitives

    @Test("field truncates + pads, right- and left-aligned (MUSHclient %w.w s)")
    func fieldFormatting() {
        #expect(MapperOutput.field("aylor", 10) == "     aylor") // right-aligned in 10
        #expect(MapperOutput.field("Aylor", 39, leftAlign: true) == "Aylor" + String(
            repeating: " ",
            count: 34
        ))
        #expect(MapperOutput.field("toolongvalue", 5) == "toolo") // truncate to width
        #expect(MapperOutput.field("toolongvalue", 5, leftAlign: true) == "toolo")
        #expect(MapperOutput.field("2", 8) == "       2")
    }

    @Test("border matches the reference's literal `hl` for the areas table")
    func borderMatchesReference() {
        // Verbatim from aard_GMCP_mapper.xml map_areas (`hl`).
        let reference = "+------------+-----------------------------------------+----------+"
        #expect(MapperOutput.border([10, 39, 8]) == reference)
    }

    @Test("row joins field-formatted cells with the pipe frame")
    func rowFraming() {
        #expect(MapperOutput.row(["a", "b", "c"]) == "| a | b | c |")
    }

    @Test("gotoRow is a clickable segment dispatching `mapper goto <uid>`")
    func gotoRowIsClickable() {
        guard case .colourNote(let segments) = MapperOutput.gotoRow("Aylor", uid: "32418"),
              let segment = segments.first
        else { Issue.record("expected a colourNote segment"); return }
        #expect(segment.foreground == MapperOutput.noteColour)
        #expect(segment.link?.action == .sendCommand("mapper goto 32418"))
    }

    @Test("note + error use the reference mapper colours (lightgreen / red)")
    func noteColours() {
        #expect(MapperOutput.noteColour == "#90EE90") // ColourNameToRGB "lightgreen"
        #expect(MapperOutput.errorColour == "#FF0000") // ColourNameToRGB "red"
    }

    // MARK: - `mapper areas` end-to-end

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { segs.map(\.text).joined() } else { nil }
        }
    }

    @Test("mapper areas renders the reference table byte-for-byte")
    func areasTableMatchesReference() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-areas-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let mapper = try Mapper(store: MapperStore(url: url))

        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"midgaard","name":"Midgaard"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"A","zone":"aylor","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"B","zone":"aylor","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"C","zone":"midgaard","exits":{}}"#
        )

        let out = await notes(mapper.handleCommand("mapper areas"))
        let border = "+------------+-----------------------------------------+----------+"
        #expect(out == [
            "",
            "The following areas have been mapped:",
            border,
            "| keyword    | Area Name                               | Explored |",
            border,
            "|      aylor | Aylor                                   |        2 |",
            "|   midgaard | Midgaard                                |        1 |",
            border,
            "Found 2 areas containing 3 rooms mapped.",
            ""
        ])
    }

    @Test("mapper areas filters by name and reports the matching intro")
    func areasTableFilters() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-areas-f-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"midgaard","name":"Midgaard"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"A","zone":"aylor","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"C","zone":"midgaard","exits":{}}"#
        )

        let out = await notes(mapper.handleCommand("mapper areas mid"))
        #expect(out.contains("The following areas matching 'mid' have been mapped:"))
        #expect(out.contains("|   midgaard | Midgaard                                |        1 |"))
        #expect(!out.contains { $0.contains("Aylor") })
        #expect(out.contains("Found 1 areas containing 1 rooms mapped."))
    }
}
