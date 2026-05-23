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

/// A laid-out map: rooms placed on an integer grid by a fan-out BFS from the
/// current room, plus the connectors between them. A faithful port of the
/// Aardwolf `aardmapper.lua` `draw_room` algorithm (grid placement +
/// collision→stub handling), kept as a pure value type so the layout is
/// unit-testable without any UI.
///
/// Cardinal exits map to orthogonal cells; **up renders to the NE cell, down
/// to the SW** (matching the original). Diagonal/custom-command exits aren't
/// placed (they have no grid delta), exactly as the original skips them.
public struct MapLayout: Sendable, Equatable {
    public let current: String
    public let rooms: [PlacedRoom]
    public let links: [MapLink]
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
        showOtherAreas: Bool = true
    ) -> MapLayout {
        guard graph.rooms[current] != nil else {
            return MapLayout(current: current, rooms: [], links: [], minX: 0, minY: 0, maxX: 0, maxY: 0)
        }
        let currentArea = graph.rooms[current]?.area

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
                    currentArea: currentArea
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

        let xs = rooms.map(\.point.x)
        let ys = rooms.map(\.point.y)
        return MapLayout(
            current: current,
            rooms: rooms,
            links: links,
            minX: xs.min() ?? 0,
            minY: ys.min() ?? 0,
            maxX: xs.max() ?? 0,
            maxY: ys.max() ?? 0
        )
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

    private static func makePlaced(
        uid: String, point: GridPoint, graph: RoomGraph, currentUID: String, currentArea: String?
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
            note: room.notes,
            exits: room.exits.keys.sorted()
        )
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
        minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int
    ) {
        self.current = current
        self.rooms = rooms
        self.links = links
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}
