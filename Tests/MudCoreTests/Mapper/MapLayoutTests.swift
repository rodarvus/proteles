@testable import MudCore
import Testing

@Suite("Mapper — fan-out BFS layout")
struct MapLayoutTests {
    /// Build a graph from `uid → [dir: dest]`. Rooms default to area `"z"`
    /// unless overridden in `areaByUID`; `areaNames` names areas for display.
    private func graph(
        _ exitsByUID: [String: [String: String]],
        areaByUID: [String: String] = [:],
        areaNames: [String: String] = [:]
    ) -> RoomGraph {
        var graph = RoomGraph()
        for (uid, exits) in exitsByUID {
            var mapped: [String: Exit] = [:]
            for (dir, dest) in exits {
                mapped[dir] = Exit(dir: dir, to: dest)
            }
            graph.rooms[uid] = Room(
                uid: uid,
                name: "Room \(uid)",
                area: areaByUID[uid] ?? "z",
                exits: mapped
            )
        }
        for (uid, name) in areaNames {
            graph.areas[uid] = Area(uid: uid, name: name)
        }
        return graph
    }

    private func placed(_ layout: MapLayout, _ uid: String) -> PlacedRoom? {
        layout.rooms.first { $0.uid == uid }
    }

    @Test("Current room sits at the origin")
    func origin() {
        let layout = MapLayout.build(graph: graph(["1": [:]]), current: "1")
        #expect(placed(layout, "1")?.point == .zero)
        #expect(placed(layout, "1")?.relation == .current)
    }

    @Test("Cardinal exits fan out one cell each (y grows downward)")
    func cardinals() {
        let g = graph([
            "1": ["n": "2", "s": "3", "e": "4", "w": "5"],
            "2": ["s": "1"], "3": ["n": "1"], "4": ["w": "1"], "5": ["e": "1"]
        ])
        let layout = MapLayout.build(graph: g, current: "1")
        #expect(placed(layout, "2")?.point == GridPoint(x: 0, y: -1)) // north = up-screen
        #expect(placed(layout, "3")?.point == GridPoint(x: 0, y: 1))
        #expect(placed(layout, "4")?.point == GridPoint(x: 1, y: 0))
        #expect(placed(layout, "5")?.point == GridPoint(x: -1, y: 0))
    }

    @Test("Up renders to the NE cell, down to the SW")
    func upDownDiagonals() {
        let g = graph(["1": ["u": "2", "d": "3"], "2": ["d": "1"], "3": ["u": "1"]])
        let layout = MapLayout.build(graph: g, current: "1")
        #expect(placed(layout, "2")?.point == GridPoint(x: 1, y: -1)) // NE
        #expect(placed(layout, "3")?.point == GridPoint(x: -1, y: 1)) // SW
        // The current room advertises both vertical exits for its chevrons.
        #expect(placed(layout, "1")?.hasUp == true)
        #expect(placed(layout, "1")?.hasDown == true)
    }

    @Test("A cell collision becomes a stub, not a duplicate room")
    func collisionStub() {
        // Two distinct rooms both want the NE cell (1,-1): room 5 via
        // 1-e->3-n->5, and room 4 via 1-n->2-e->4. The grid can hold only one;
        // the loser is dropped to a stub rather than overlapping.
        let g = graph([
            "1": ["n": "2", "e": "3"],
            "2": ["s": "1", "e": "4"],
            "3": ["w": "1", "n": "5"],
            "4": ["w": "2"],
            "5": ["s": "3"]
        ])
        let layout = MapLayout.build(graph: g, current: "1")
        // Exactly one of the colliding rooms gets the cell; the other is stubbed.
        let placed4 = placed(layout, "4") != nil
        let placed5 = placed(layout, "5") != nil
        #expect(placed4 != placed5)
        #expect(layout.links.contains { $0.isStub })
        // No two placed rooms share a cell.
        #expect(Set(layout.rooms.map(\.point)).count == layout.rooms.count)
    }

    @Test("Unknown destinations draw a dotted stub and aren't placed")
    func unknownDestination() {
        let g = graph(["1": ["n": "0", "e": "2"], "2": ["w": "1"]])
        let layout = MapLayout.build(graph: g, current: "1")
        #expect(placed(layout, "0") == nil)
        #expect(layout.links.contains { $0.dir == "n" && $0.isStub && $0.isUnknownDestination })
    }

    @Test("Room kind is classified from tags in priority order")
    func roomKinds() {
        #expect(MapLayout.kind(for: ["shop", "safe"]) == .shop)
        #expect(MapLayout.kind(for: ["safe"]) == .safe)
        #expect(MapLayout.kind(for: ["healer", "bank"]) == .healer)
        #expect(MapLayout.kind(for: []) == .normal)
    }

    @Test("Cross-area neighbours are flagged otherArea")
    func areaRelation() {
        let g = graph(
            ["1": ["n": "2"], "2": ["s": "1"]],
            areaByUID: ["1": "aylor", "2": "elsewhere"],
            areaNames: ["aylor": "Aylor", "elsewhere": "Far Away"]
        )
        let layout = MapLayout.build(graph: g, current: "1")
        #expect(placed(layout, "2")?.relation == .otherArea)
        #expect(placed(layout, "2")?.areaName == "Far Away")
    }

    @Test("showOtherAreas:false stubs cross-area exits instead of placing them")
    func hideOtherAreas() {
        let g = graph(
            ["1": ["n": "2"], "2": ["s": "1"]],
            areaByUID: ["1": "aylor", "2": "elsewhere"]
        )
        let layout = MapLayout.build(graph: g, current: "1", showOtherAreas: false)
        #expect(placed(layout, "2") == nil)
        #expect(layout.links.contains { $0.dir == "n" && $0.isStub })
    }

    @Test("One-way exits are detected")
    func oneWay() {
        // 1-n->2 but 2 has no way back to 1.
        let g = graph(["1": ["n": "2"], "2": [:]])
        let layout = MapLayout.build(graph: g, current: "1")
        #expect(layout.links.contains { $0.dir == "n" && $0.isOneWay && !$0.isStub })
    }

    @Test("maxRooms caps the placement count")
    func depthCap() {
        // A long corridor 1-n->2-n->3 ... 20.
        var rows: [String: [String: String]] = [:]
        for index in 1...20 {
            var exits: [String: String] = [:]
            if index < 20 { exits["n"] = String(index + 1) }
            if index > 1 { exits["s"] = String(index - 1) }
            rows[String(index)] = exits
        }
        let layout = MapLayout.build(graph: graph(rows), current: "1", maxRooms: 5)
        #expect(layout.rooms.count <= 5 + 1) // ring granularity tolerance
    }

    @Test("Unknown current room yields an empty layout")
    func unknownCurrent() {
        let layout = MapLayout.build(graph: graph(["1": [:]]), current: "999")
        #expect(layout.isEmpty)
    }

    @Test("Terrain resolves to an ANSI colour index (by name and by env id)")
    func terrainColour() {
        var graph = RoomGraph()
        // Room 1's terrain is the sector *name*; room 2's is a numeric env id.
        graph.rooms["1"] = Room(
            uid: "1",
            name: "A",
            area: "z",
            terrain: "forest",
            exits: ["n": Exit(dir: "n", to: "2")]
        )
        graph.rooms["2"] = Room(
            uid: "2",
            name: "B",
            area: "z",
            terrain: "4",
            exits: ["s": Exit(dir: "s", to: "1")]
        )
        let layout = MapLayout.build(
            graph: graph,
            current: "1",
            terrainColours: ["forest": 10, "water": 4],
            environments: ["4": "water"]
        )
        #expect(placed(layout, "1")?.terrainColorIndex == 10) // forest → 10
        #expect(placed(layout, "2")?.terrainColorIndex == 4) // env id 4 → "water" → 4
    }
}
