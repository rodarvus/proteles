import Foundation
@testable import MudCore
import Testing

/// Phase 2 of the mapper-fidelity work: search commands. Strings + clickable
/// rows checked against the reference `aardmapper.lua` `full_find`/`find` and
/// `aard_GMCP_mapper.xml` `map_find`/`map_area`/`map_list`.
@Suite("Mapper — search commands (Phase 2)")
struct MapperSearchTests {
    /// Two "Aylor …" rooms (1 —e→ 2) in area `aylor`, plus a Midgaard room, with
    /// room 1 the current room (ingested last).
    private func makeMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-search-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"midgaard","name":"Midgaard"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Midgaard Inn","zone":"midgaard","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Aylor Gate","zone":"aylor","exits":{"w":1}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Aylor Square","zone":"aylor","exits":{"e":2}}"#
        )
        return mapper
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { segs.map(\.text).joined() } else { nil }
        }
    }

    private func link(_ effect: ScriptEffect) -> LineLink? {
        if case .colourNote(let segs) = effect { segs.first?.link } else { nil }
    }

    private func mapperBroadcasts(_ effects: [ScriptEffect]) -> [(id: Int, text: String)] {
        effects.compactMap {
            if case .mapperBroadcast(let id, let text) = $0 { (id, text) } else { nil }
        }
    }

    private let start = "+------------------------------ START OF SEARCH -------------------------------+"
    private let end = "+-------------------------------- END OF SEARCH -------------------------------+"

    // MARK: - find (full_find)

    @Test("find renders the full_find frame, count, distances, and clickable rows")
    func findFullFind() async throws {
        let mapper = try await makeMapper()
        let effects = await mapper.handleCommand("mapper find aylor")
        let broadcasts = mapperBroadcasts(effects)
        #expect(broadcasts.map(\.id) == [500, 501])
        #expect(broadcasts[0].text.contains(#"["1"]"#))
        #expect(broadcasts[0].text.contains(#"["2"]"#))
        #expect(broadcasts[0].text.contains(#"reason = true"#))
        #expect(broadcasts[1].text == "unfound_paths = {  }")
        let out = notes(effects)
        // Pattern is echoed verbatim with the SQL wildcards.
        #expect(out.first == "Found 2 targets matching '%aylor%'.")
        #expect(out.contains(start))
        #expect(out.contains(end))
        // Room 1 is current → plain row, distance 0; room 2 is one step → [1].
        #expect(out.contains("Aylor Square (aylor)"))
        #expect(out.contains(" - 0 rooms away"))
        #expect(out.contains("[1] Aylor Gate (aylor)"))
        #expect(out.contains(" - 1 room away"))
        // The Midgaard room must not appear.
        #expect(!out.contains { $0.contains("Midgaard") })
    }

    @Test("find rows are clickable and dispatch `mapper goto <uid>`")
    func findClickable() async throws {
        let mapper = try await makeMapper()
        let effects = await mapper.handleCommand("mapper find aylor")
        // The "[1] Aylor Gate" row carries the goto link for room 2.
        let row = effects.first { link($0)?.action == .sendCommand("mapper goto 2") }
        #expect(row != nil)
    }

    @Test("find populates the result list so `next` walks it")
    func findFeedsNext() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper find aylor")
        // Room 2 is the single non-current result → next walks to it.
        let next = await mapper.handleCommand("mapper next")
        let walks = next.compactMap { if case .execute(let text) = $0 { text } else { nil } }
        #expect(walks == ["run e"])
    }

    @Test("a quoted find matches exactly, not as a substring")
    func findQuoted() async throws {
        let mapper = try await makeMapper()
        let out = await notes(mapper.handleCommand(#"mapper find "Aylor Gate""#))
        #expect(out.first == "Found 1 target matching 'Aylor Gate'.")
        #expect(out.contains("[1] Aylor Gate (aylor)"))
        #expect(!out.contains { $0.contains("Aylor Square") })
    }

    @Test("find with no current room reports the LOOK hint")
    func findNoCurrentRoom() async throws {
        let mapper = try await makeMapper()
        await mapper.clearCurrentRoom()
        #expect(await notes(mapper.handleCommand("mapper find aylor"))
            == ["I don't know where you are right now - try: LOOK"])
    }

    // MARK: - area (full_find within current area)

    @Test("area with no argument lists the current area's rooms via full_find")
    func areaCurrent() async throws {
        let mapper = try await makeMapper()
        let out = await notes(mapper.handleCommand("mapper area"))
        // Current area is aylor (2 rooms); empty pattern → %%.
        #expect(out.first == "Found 2 targets matching '%%'.")
        #expect(out.contains("[1] Aylor Gate (aylor)"))
        #expect(!out.contains { $0.contains("Midgaard") })
    }

    @Test("area with no known room reports the LOOK error")
    func areaNoRoom() async throws {
        let mapper = try await makeMapper()
        await mapper.clearCurrentRoom()
        #expect(await notes(mapper.handleCommand("mapper area"))
            == ["I do not know your room! Try typing 'LOOK' first."])
    }

    // MARK: - list (map_list)

    @Test("list renders the non-clickable FTS listing with uid + area keyword")
    func listListing() async throws {
        let mapper = try await makeMapper()
        let effects = await mapper.handleCommand("mapper list aylor")
        let out = notes(effects)
        #expect(out.first == start)
        #expect(out.contains(#"(1) Aylor Square is in area "aylor""#))
        #expect(out.contains(#"(2) Aylor Gate is in area "aylor""#))
        #expect(out.last == end)
        // list rows are plain text, not hyperlinks.
        #expect(effects.allSatisfy { link($0) == nil })
    }

    // MARK: - special searches (shops/train/quest/heal)

    /// Room 1 (current, no info) —e→ room 2 (a shop+bank), area aylor.
    private func makeShopMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-shop-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Bank Lobby","zone":"aylor","details":"shop,bank","exits":{"w":1}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","exits":{"e":2}}"#
        )
        return mapper
    }

    @Test("shops searches via quick_find: intro, count, clickable, reason line")
    func shopsSearch() async throws {
        let mapper = try await makeShopMapper()
        let effects = await mapper.handleCommand("mapper shops")
        let out = notes(effects)
        #expect(out.first == "Searching all areas")
        #expect(out.contains("Found 1 target matching 'shop,bank'."))
        #expect(out.contains(start))
        #expect(out.contains("[1] Bank Lobby (aylor)"))
        // reason: matched info keywords, Capitalised, comma-joined; " - " + " [..]".
        #expect(out.contains(" -  [Shop, Bank]"))
        #expect(out.contains(end))
        // The row is clickable to room 2.
        #expect(effects.contains { link($0)?.action == .sendCommand("mapper goto 2") })
    }

    @Test("shops here scopes to the current area")
    func shopsHere() async throws {
        let mapper = try await makeShopMapper()
        #expect(await notes(mapper.handleCommand("mapper shops here")).first == "Searching current area")
    }

    // MARK: - unmapped (two-mode bordered table)

    /// Room 1 (current) has a mapped exit (e→2) and an unmapped one (n→99).
    private func makeUnmappedMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-unmapped-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Gate","zone":"aylor","exits":{"w":1}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"One","zone":"aylor","exits":{"e":2,"n":99}}"#
        )
        return mapper
    }

    @Test("unmapped with no argument renders the by-area count table")
    func unmappedByArea() async throws {
        let mapper = try await makeUnmappedMapper()
        let out = await notes(mapper.handleCommand("mapper unmapped"))
        #expect(out.contains("The following areas have unmapped exits:"))
        #expect(out.contains("+------------+-------+"))
        #expect(out.contains("| area       | count |"))
        #expect(out.contains("|      aylor |     1 |"))
        #expect(out.contains("Found 1 unmapped exits."))
    }

    @Test("unmapped here renders the clickable per-exit table")
    func unmappedHere() async throws {
        let mapper = try await makeUnmappedMapper()
        let effects = await mapper.handleCommand("mapper unmapped here")
        let out = notes(effects)
        #expect(out.contains("The following rooms in the current area have unmapped exits:"))
        #expect(out.contains("+------------+----------------------+---------+-----+---------+"))
        #expect(out.contains("| area       | room name            | rm uid  | dir | to uid  |"))
        // The unmapped exit n→99 from room 1, field-formatted per the reference fmt.
        #expect(out.contains("|      aylor | One                  |       1 | n   |      99 |"))
        #expect(out.contains("Found 1 unmapped exits."))
        // Per-exit rows are clickable (mapper goto the source room).
        #expect(effects.contains { link($0)?.action == .sendCommand("mapper goto 1") })
    }
}
