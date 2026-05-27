import Foundation
@testable import MudCore
import Testing

@Suite("Mapper — GMCP ingestion")
struct MapperTests {
    private func freshMapper() throws -> (Mapper, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-ingest-\(UUID().uuidString).db")
        let store = try MapperStore(url: url)
        return try (Mapper(store: store), url)
    }

    @Test("A fresh mapper seeds the terrain palette from the persisted environments table")
    func seedsTerrainPaletteFromStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-seed-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        // Persist a sector palette (as a prior session / DB import would have).
        let store = try MapperStore(url: url)
        try store.replaceEnvironments([
            .init(uid: "2", name: "city", color: 7),
            .init(uid: "10", name: "forest", color: 10)
        ])
        // A *fresh* mapper on the same DB — no live room.sectors this session —
        // must still know the palette, so imported rooms colour (not grey).
        let mapper = try Mapper(store: MapperStore(url: url))
        #expect(await mapper.terrainColours["city"] == 7)
        #expect(await mapper.terrainColours["forest"] == 10)
        #expect(await mapper.environments["2"] == "city")
    }

    @Test("room.info upserts the room, its exits, and a stub area; requests the area name")
    func ingestRoomInfo() async throws {
        let (mapper, url) = try freshMapper()
        defer { try? FileManager.default.removeItem(at: url) }

        let requests = await mapper.ingest(package: "room.info", json: """
        {"num":676,"name":"A Dusty Wagon Trail","zone":"childsplay","terrain":"road",
         "details":"shop,safe","exits":{"n":677,"e":678},"coord":{"x":3,"y":4,"cont":0}}
        """)

        let graph = await mapper.graph
        let room = try #require(graph.rooms["676"])
        #expect(room.name == "A Dusty Wagon Trail")
        #expect(room.area == "childsplay")
        #expect(room.terrain == "road")
        #expect(room.tags == ["shop", "safe"])
        #expect(room.exits["n"]?.to == "677")
        #expect(room.exits["e"]?.to == "678")
        #expect(room.x == 3 && room.y == 4)
        #expect(await mapper.currentRoomUID == "676")
        // A stub area was created and its name requested.
        #expect(graph.areas["childsplay"] != nil)
        #expect(requests.contains("request area"))
    }

    @Test("Unmappable rooms (num -1) get a synthetic nomap uid")
    func nomapRoom() async throws {
        let (mapper, url) = try freshMapper()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":-1,"name":"The Void","zone":"limbo","exits":{}}"#
        )
        #expect(await mapper.currentRoomUID == "nomap_The Void_limbo")
    }

    @Test("Re-ingesting the same room data doesn't change the graph; a real change updates it")
    func changeDetection() async throws {
        let (mapper, url) = try freshMapper()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"{"num":1,"name":"A","zone":"z","exits":{"n":2}}"#
        _ = await mapper.ingest(package: "room.info", json: json)
        let first = await mapper.graph.rooms["1"]
        _ = await mapper.ingest(package: "room.info", json: json)
        #expect(await mapper.graph.rooms["1"] == first)

        // A new exit destination is reflected.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"A","zone":"z","exits":{"n":3}}"#
        )
        #expect(await mapper.graph.rooms["1"]?.exits["n"]?.to == "3")
    }

    @Test("room.area fills in the area name/colour; no further request")
    func ingestArea() async throws {
        let (mapper, url) = try freshMapper()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"A","zone":"childsplay","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.area",
            json: #"{"id":"childsplay","name":"Childsplay","col":"@g","flags":""}"#
        )
        let area = try #require(await mapper.graph.areas["childsplay"])
        #expect(area.name == "Childsplay")
        #expect(area.color == "@g")
        // Now that the name is known, a second room.info doesn't re-request.
        let requests = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"B","zone":"childsplay","exits":{}}"#
        )
        #expect(!requests.contains("request area"))
    }

    @Test("room.sectors populates the environment/terrain colour tables")
    func ingestSectors() async throws {
        let (mapper, url) = try freshMapper()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await mapper.ingest(package: "room.sectors", json: """
        {"sectors":[{"id":1,"name":"road","color":8421504},{"id":2,"name":"water","color":255}]}
        """)
        #expect(await mapper.environments["1"] == "road")
        #expect(await mapper.terrainColours["water"] == 255)
    }

    @Test("Ingested data persists and reloads via the store")
    func persistAndReload() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-reload-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let mapper = try Mapper(store: MapperStore(url: url))
            _ = await mapper.ingest(
                package: "room.info",
                json: #"{"num":42,"name":"Home","zone":"z","exits":{"s":43}}"#
            )
        }
        // A fresh Mapper over the same file sees the room.
        let reopened = try Mapper(store: MapperStore(url: url))
        #expect(await reopened.graph.rooms["42"]?.name == "Home")
        #expect(await reopened.graph.rooms["42"]?.exits["s"]?.to == "43")
    }

    @Test("Map view toggles persist per profile and restore on reopen")
    func togglesPersist() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-toggles-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let mapper = try Mapper(store: MapperStore(url: url))
            #expect(await mapper.showOtherAreas == false) // default
            await mapper.setShowOtherAreas(true)
            await mapper.setShowAreaExits(true)
        }
        // A fresh Mapper over the same file restores both toggles.
        let reopened = try Mapper(store: MapperStore(url: url))
        #expect(await reopened.showOtherAreas == true)
        #expect(await reopened.showAreaExits == true)
    }
}
