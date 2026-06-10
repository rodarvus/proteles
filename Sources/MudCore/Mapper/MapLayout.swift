import Foundation

/// A grid cell in map space. The current room sits at the origin; each
/// cardinal exit moves exactly one cell (`y` grows downward, screen-style).
public struct GridPoint: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static let zero = GridPoint(x: 0, y: 0)

    public static func + (lhs: GridPoint, rhs: GridPoint) -> GridPoint {
        GridPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
}

/// What kind of special room this is, for fill colour + glyph. Classified
/// from ``Room/tags`` (the `info` comma-list), in the same priority order as
/// the Aardwolf mapper.
public enum RoomKind: String, Sendable, Equatable {
    case normal, shop, healer, trainer, guild, questor, bank, safe
    /// A room we have an exit to but no stored data for.
    case unknown
}

/// How a placed room relates to the current room's area — drives border
/// colour and dimming.
public enum RoomRelation: String, Sendable, Equatable {
    case current, sameArea, otherArea
}

/// One room positioned on the map grid, with everything the view needs to
/// draw and describe it (no graph lookups required at render time).
public struct PlacedRoom: Sendable, Equatable, Identifiable {
    public let uid: String
    public let point: GridPoint
    public let name: String
    public let areaName: String?
    public let kind: RoomKind
    public let relation: RoomRelation
    public let hasNote: Bool
    public let hasUp: Bool
    public let hasDown: Bool
    public let isPK: Bool
    /// Area border tint string (as stored), if any.
    public let areaColor: String?
    public let terrain: String?
    /// Resolved terrain colour as an ANSI palette index (0–15), or nil when
    /// the terrain/sector palette doesn't cover it. The view maps this to a
    /// fill — matching the Aardwolf mapper's terrain colouring.
    public let terrainColorIndex: Int?
    public let note: String?
    /// Sorted exit directions/commands, for the tooltip.
    public let exits: [String]

    public var id: String {
        uid
    }
}

/// One drawn connector. The line starts at `from` (a placed room's centre)
/// and heads in `dir`; the view derives the endpoint (full links reach the
/// next cell, stubs are short). Style flags mirror the Aardwolf mapper.
public struct MapLink: Sendable, Equatable {
    public let from: GridPoint
    public let dir: String
    /// A stub is a half-line (collision, self-loop, another-area edge, or a
    /// link to an already-planned room) — it doesn't reach a drawn room.
    public let isStub: Bool
    public let isUpDown: Bool
    public let isLocked: Bool
    public let isOneWay: Bool
    /// The destination room is unknown (the MUD hasn't told us where it
    /// goes) — drawn dotted.
    public let isUnknownDestination: Bool
}

/// A boundary marker for an exit that leaves the current area, drawn as a
/// highlighted bar on the edge of `from` in direction `dir` (Aardwolf's
/// `SHOW_AREA_EXITS`). One per neighbouring area, on the nearest boundary
/// room. `area` is the destination area's display name (for the label).
public struct AreaExitMarker: Sendable, Equatable {
    public let from: GridPoint
    public let dir: String
    public let area: String
    /// Destination room uid (the boundary room is clickable to walk there).
    public let destUID: String
}

/// A laid-out map: rooms placed on an integer grid by a fan-out BFS from the
/// current room, plus the connectors between them. Uses the same general
/// grid-placement approach Aardwolf mappers do (BFS fan-out with
/// collision→stub handling) — an independent implementation, kept as a pure
/// value type so the layout is unit-testable without any UI.
///
/// Cardinal exits map to orthogonal cells; **up renders to the NE cell, down
/// to the SW** (matching the original). Diagonal/custom-command exits aren't
/// placed (they have no grid delta), exactly as the original skips them.
public struct MapLayout: Sendable, Equatable {
    public let current: String
    public let rooms: [PlacedRoom]
    public let links: [MapLink]
    /// Boundary markers for exits leaving the current area (empty unless
    /// `showAreaExits` was requested).
    public let areaExits: [AreaExitMarker]
    /// Render hint: animate the PK warning (Aardwolf's `BLINK_PK_TITLE`).
    /// Carried on the layout so a runtime toggle reaches the view live.
    public let pkBlink: Bool
    /// Background texture filename for the current room's area, drawn tiled
    /// behind the map (the reference mapper's per-area `texture` with its
    /// `test5.png` room-level default) — nil when textures are off. The view
    /// resolves the name against `~/Documents/Proteles/MapImages/`; a missing
    /// file means a plain background (Proteles ships no image assets, #11).
    public let areaTexture: String?
    /// Set while the player is overland (GMCP `coord.cont == 1`): the graph
    /// fan-out is meaningless there, so the layout carries no rooms and the
    /// panel renders the captured continent bigmap instead (the reference
    /// halts the GMCP mapper's drawing and shows the Bigmap window). `zone`
    /// is the continent id (`coord.id`); `x`/`y` the 0-based cell on the
    /// border-stripped bigmap grid (`coord.x`/`coord.y`).
    public let continent: Continent?

    /// Overland position (see ``continent``).
    public struct Continent: Sendable, Equatable {
        public let zone: Int
        public let x: Int
        public let y: Int

        public init(zone: Int, x: Int, y: Int) {
            self.zone = zone
            self.x = x
            self.y = y
        }
    }

    /// Bounding box of placed rooms, in grid units (origin = current room).
    public let minX: Int
    public let minY: Int
    public let maxX: Int
    public let maxY: Int

    public var isEmpty: Bool {
        rooms.isEmpty
    }

    /// Grid delta per placeable direction. Up = NE, down = SW.
    public static let gridDelta: [String: GridPoint] = [
        "n": GridPoint(x: 0, y: -1),
        "s": GridPoint(x: 0, y: 1),
        "e": GridPoint(x: 1, y: 0),
        "w": GridPoint(x: -1, y: 0),
        "u": GridPoint(x: 1, y: -1),
        "d": GridPoint(x: -1, y: 1)
    ]

    static let inverse: [String: String] = [
        "n": "s", "s": "n", "e": "w", "w": "e", "u": "d", "d": "u"
    ]

    /// Build the layout for `current` over `graph`. `maxDepth` bounds the BFS
    /// ring count and `maxRooms` caps total placements (both protect against
    /// huge graphs); `showOtherAreas` controls whether cross-area neighbours
    /// are drawn as rooms or just stubs.
    public static func build(
        graph: RoomGraph,
        current: String,
        maxDepth: Int = 60,
        maxRooms: Int = 600,
        showOtherAreas: Bool = true,
        showAreaExits: Bool = false,
        pkBlink: Bool = true,
        useTextures: Bool = false,
        terrainColours: [String: Int] = [:],
        environments: [String: String] = [:]
    ) -> MapLayout {
        guard graph.rooms[current] != nil else {
            return MapLayout(
                current: current,
                rooms: [],
                links: [],
                areaExits: [],
                pkBlink: pkBlink,
                areaTexture: nil,
                continent: nil,
                minX: 0,
                minY: 0,
                maxX: 0,
                maxY: 0
            )
        }
        let currentArea = graph.rooms[current]?.area
        let palette = TerrainPalette(colours: terrainColours, environments: environments)
        let (rooms, links) = fanOut(
            graph: graph,
            current: current,
            currentArea: currentArea,
            palette: palette,
            maxDepth: maxDepth,
            maxRooms: maxRooms,
            showOtherAreas: showOtherAreas
        )
        let areaExits = showAreaExits
            ? collectAreaExits(rooms: rooms, graph: graph, currentArea: currentArea)
            : []
        let xs = rooms.map(\.point.x)
        let ys = rooms.map(\.point.y)
        return MapLayout(
            current: current,
            rooms: rooms,
            links: links,
            areaExits: areaExits,
            pkBlink: pkBlink,
            areaTexture: useTextures ? textureName(for: currentArea, graph: graph) : nil,
            continent: nil,
            minX: xs.min() ?? 0,
            minY: ys.min() ?? 0,
            maxX: xs.max() ?? 0,
            maxY: ys.max() ?? 0
        )
    }

    /// The texture file for an area: its `texture` column, falling back to the
    /// reference's room-level default (`test5.png` in aardmapper.lua's
    /// `get_room`) when the area has none recorded.
    static func textureName(for area: String?, graph: RoomGraph) -> String? {
        let name = area.flatMap { graph.areas[$0]?.texture }
        guard let name, !name.isEmpty else { return "test5.png" }
        return name
    }

    /// The overland layout: no placed rooms (the fan-out is halted, like the
    /// reference's `halt_drawing`), just the continent position for the
    /// bigmap render.
    public static func continent(
        current: String,
        zone: Int,
        x: Int,
        y: Int,
        pkBlink: Bool = true
    ) -> MapLayout {
        MapLayout(
            current: current,
            rooms: [],
            links: [],
            areaExits: [],
            pkBlink: pkBlink,
            areaTexture: nil,
            continent: Continent(zone: zone, x: x, y: y),
            minX: 0,
            minY: 0,
            maxX: 0,
            maxY: 0
        )
    }

    // swiftlint:disable function_parameter_count
    /// The fan-out BFS itself: place rooms ring-by-ring from `current` and
    /// build the connectors between them. Split out of ``build`` to keep each
    /// within the body-length budget.
    private static func fanOut(
        graph: RoomGraph,
        current: String,
        currentArea: String?,
        palette: TerrainPalette,
        maxDepth: Int,
        maxRooms: Int,
        showOtherAreas: Bool
    ) -> (rooms: [PlacedRoom], links: [MapLink]) {
        // swiftlint:enable function_parameter_count
        var placed: [String: GridPoint] = [:] // uid → where it was drawn (dedupe)
        var occupied: [GridPoint: String] = [GridPoint.zero: current] // cell → uid
        var planned: [String: GridPoint] = [current: .zero] // uid → reserved cell
        var rooms: [PlacedRoom] = []
        var links: [MapLink] = []

        var frontier: [(uid: String, point: GridPoint)] = [(current, .zero)]
        var depth = 0
        while !frontier.isEmpty, depth < maxDepth, rooms.count < maxRooms {
            var next: [(uid: String, point: GridPoint)] = []
            for (uid, point) in frontier {
                if placed[uid] != nil { continue } // already drawn this room
                placed[uid] = point
                rooms.append(makePlaced(
                    uid: uid,
                    point: point,
                    graph: graph,
                    currentUID: current,
                    currentArea: currentArea,
                    palette: palette
                ))

                // Unknown rooms carry no exits to traverse.
                guard let room = graph.rooms[uid] else { continue }
                for dir in room.exits.keys.sorted() {
                    guard let exit = room.exits[dir], let delta = gridDelta[dir] else { continue }
                    appendExit(
                        from: uid,
                        at: point,
                        dir: dir,
                        delta: delta,
                        exit: exit,
                        graph: graph,
                        currentArea: currentArea,
                        showOtherAreas: showOtherAreas,
                        occupied: &occupied,
                        planned: &planned,
                        next: &next,
                        links: &links
                    )
                }
            }
            frontier = next
            depth += 1
        }
        return (rooms, links)
    }

    /// One boundary marker per neighbouring area, on the nearest current-area
    /// room with a known exit leaving the zone (Aardwolf's `SHOW_AREA_EXITS`).
    private static func collectAreaExits(
        rooms: [PlacedRoom], graph: RoomGraph, currentArea: String?
    ) -> [AreaExitMarker] {
        var markers: [AreaExitMarker] = []
        var seenAreas: Set<String> = []
        for placed in rooms {
            guard placed.relation == .current || placed.relation == .sameArea,
                  let room = graph.rooms[placed.uid] else { continue }
            for dir in room.exits.keys.sorted() {
                guard gridDelta[dir] != nil, let exit = room.exits[dir],
                      let dest = graph.rooms[exit.to], let destArea = dest.area,
                      destArea != currentArea, seenAreas.insert(destArea).inserted
                else { continue }
                markers.append(AreaExitMarker(
                    from: placed.point,
                    dir: dir,
                    area: graph.areas[destArea]?.name ?? destArea,
                    destUID: exit.to
                ))
            }
        }
        return markers
    }

    // MARK: - Exit placement (mirrors draw_room's per-exit decision tree)

    // swiftlint:disable:next function_parameter_count
    private static func appendExit(
        from uid: String,
        at point: GridPoint,
        dir: String,
        delta: GridPoint,
        exit: Exit,
        graph: RoomGraph,
        currentArea: String?,
        showOtherAreas: Bool,
        occupied: inout [GridPoint: String],
        planned: inout [String: GridPoint],
        next: inout [(uid: String, point: GridPoint)],
        links: inout [MapLink]
    ) {
        let destUID = exit.to
        let nextPoint = point + delta
        let destRoom = graph.rooms[destUID]
        let isUD = dir == "u" || dir == "d"
        let isLocked = exit.door == .locked
        let usable = !destUID.isEmpty && destUID != "0"

        func stub(unknownDest: Bool = false) {
            links.append(MapLink(
                from: point,
                dir: dir,
                isStub: true,
                isUpDown: isUD,
                isLocked: isLocked,
                isOneWay: false,
                isUnknownDestination: unknownDest
            ))
        }

        // Up/down stay on a single 2D plane: drawn only as a short diagonal
        // stub indicator (paired with the room's ▲/▼ chevron), never expanded
        // into a placed room. Matches the Aardwolf mapper's default
        // (`show_up_down = false`).
        if isUD {
            stub()
            return
        }
        // Unknown destination (the MUD hasn't told us where it leads).
        if !usable {
            stub(unknownDest: true)
            return
        }
        // A different room already sits in the target cell → stub (can't draw a
        // second room there on a 2D grid).
        if let occ = occupied[nextPoint], occ != destUID {
            stub()
            return
        }
        // Self-loop.
        if destUID == uid {
            stub()
            return
        }
        // Cross-area neighbour while not showing other areas.
        if !showOtherAreas, let destRoom, destRoom.area != currentArea {
            stub()
            return
        }
        // Already reserved for a different cell → stub (keeps the first path).
        if let reserved = planned[destUID], reserved != nextPoint {
            stub()
            return
        }

        // Full link: one-way if the destination doesn't point back at us.
        let oneWay = destRoom.map { $0.exits[inverse[dir] ?? ""]?.to != uid } ?? false
        links.append(MapLink(
            from: point,
            dir: dir,
            isStub: false,
            isUpDown: isUD,
            isLocked: isLocked,
            isOneWay: oneWay,
            isUnknownDestination: destRoom == nil
        ))
        if planned[destUID] == nil {
            planned[destUID] = nextPoint
            occupied[nextPoint] = destUID
            next.append((destUID, nextPoint))
        }
    }

    // MARK: - Room classification

    // swiftlint:disable:next function_parameter_count
    private static func makePlaced(
        uid: String,
        point: GridPoint,
        graph: RoomGraph,
        currentUID: String,
        currentArea: String?,
        palette: TerrainPalette
    ) -> PlacedRoom {
        guard let room = graph.rooms[uid] else {
            return PlacedRoom(
                uid: uid,
                point: point,
                name: "(unexplored)",
                areaName: nil,
                kind: .unknown,
                relation: .otherArea,
                hasNote: false,
                hasUp: false,
                hasDown: false,
                isPK: false,
                areaColor: nil,
                terrain: nil,
                terrainColorIndex: nil,
                note: nil,
                exits: []
            )
        }
        let tags = Set(room.tags)
        let relation: RoomRelation = uid == currentUID
            ? .current : (room.area == currentArea ? .sameArea : .otherArea)
        return PlacedRoom(
            uid: uid,
            point: point,
            name: room.name,
            areaName: room.area.flatMap { graph.areas[$0]?.name } ?? room.area,
            kind: kind(for: tags),
            relation: relation,
            hasNote: !(room.notes ?? "").isEmpty,
            hasUp: room.exits["u"] != nil,
            hasDown: room.exits["d"] != nil,
            isPK: tags.contains("pk"),
            areaColor: room.area.flatMap { graph.areas[$0]?.color },
            terrain: room.terrain,
            terrainColorIndex: palette.colourIndex(for: room.terrain),
            note: room.notes,
            exits: room.exits.keys.sorted()
        )
    }

    /// Resolves a room's terrain to an ANSI colour index, mirroring the
    /// Aardwolf mapper: the stored terrain is either a sector *name* or a
    /// numeric environment *id* (looked up in `environments` → name), then
    /// the name maps to a colour via the `room.sectors` palette.
    struct TerrainPalette {
        let colours: [String: Int]
        let environments: [String: String]

        func colourIndex(for terrain: String?) -> Int? {
            guard let terrain, !terrain.isEmpty else { return nil }
            let name = Int(terrain) != nil ? (environments[terrain] ?? terrain) : terrain
            return colours[name]
        }
    }

    /// Classify a room by its tags, in the Aardwolf mapper's priority order.
    static func kind(for tags: Set<String>) -> RoomKind {
        if tags.contains("shop") { return .shop }
        if tags.contains("healer") { return .healer }
        if tags.contains("guild") { return .guild }
        if tags.contains("trainer") { return .trainer }
        if tags.contains("questor") { return .questor }
        if tags.contains("bank") { return .bank }
        if tags.contains("safe") { return .safe }
        return .normal
    }

    private init(
        current: String,
        rooms: [PlacedRoom],
        links: [MapLink],
        areaExits: [AreaExitMarker],
        pkBlink: Bool,
        areaTexture: String?,
        continent: Continent?,
        minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int
    ) {
        self.current = current
        self.rooms = rooms
        self.links = links
        self.areaExits = areaExits
        self.pkBlink = pkBlink
        self.areaTexture = areaTexture
        self.continent = continent
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}
