import Foundation

/// One exit from a room. `dir` is normally a compass direction (`"n"`,
/// `"se"`, `"u"`, …) but may be a custom-exit *command string* (e.g.
/// `"enter portal"`, `"dinv portal use 3456625340"`) — exactly as the
/// MUSHclient mapper stores it. `to` is the destination room uid.
///
/// Mirrors a row of the `exits` table; `weight`/`door` are Proteles
/// extensions (additive columns) used by routing.
public struct Exit: Sendable, Equatable {
    /// Door state (Proteles extension): a routing/UI hint.
    public enum Door: Int, Sendable, Equatable {
        case open = 1, closed = 2, locked = 3
    }

    public var dir: String
    public var to: String
    /// Minimum character level to use this exit (0 = none). Stored as TEXT
    /// in the DB; parsed to an Int here.
    public var level: Int
    /// Routing weight override (nil = default cost). Proteles extension.
    public var weight: Int?
    public var door: Door?

    public init(dir: String, to: String, level: Int = 0, weight: Int? = nil, door: Door? = nil) {
        self.dir = dir
        self.to = to
        self.level = level
        self.weight = weight
        self.door = door
    }
}

/// A room in the map graph. `uid` is the Aardwolf room vnum as a string —
/// or a synthetic `"nomap_<name>_<area>"` id for unmappable rooms, or the
/// pseudo-rooms `"*"` (portal) / `"**"` (recall) the mapper uses to model
/// from-anywhere travel. Mirrors a `rooms` row (+ the joined `bookmarks`
/// note).
public struct Room: Sendable, Equatable, Identifiable {
    public var uid: String
    public var name: String
    /// Area key (FK to ``Area/uid``), e.g. `"aylor"`.
    public var area: String?
    public var building: String?
    public var terrain: String?
    /// Comma list of room tags, e.g. `"shop,healer,bank,safe,pk"`.
    public var info: String?
    /// Player note (from the `bookmarks` table).
    public var notes: String?
    public var x: Int?
    public var y: Int?
    public var z: Int?
    public var noportal: Bool
    public var norecall: Bool
    public var ignoreExitsMismatch: Bool
    /// `dir` → exit. `dir` is a compass direction or a custom-exit command.
    public var exits: [String: Exit]

    public var id: String {
        uid
    }

    public init(
        uid: String,
        name: String = "",
        area: String? = nil,
        building: String? = nil,
        terrain: String? = nil,
        info: String? = nil,
        notes: String? = nil,
        x: Int? = nil,
        y: Int? = nil,
        z: Int? = nil,
        noportal: Bool = false,
        norecall: Bool = false,
        ignoreExitsMismatch: Bool = false,
        exits: [String: Exit] = [:]
    ) {
        self.uid = uid
        self.name = name
        self.area = area
        self.building = building
        self.terrain = terrain
        self.info = info
        self.notes = notes
        self.x = x
        self.y = y
        self.z = z
        self.noportal = noportal
        self.norecall = norecall
        self.ignoreExitsMismatch = ignoreExitsMismatch
        self.exits = exits
    }

    /// The room tags split from ``info`` (e.g. `["shop","safe"]`).
    public var tags: [String] {
        (info ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// An area (zone). `uid` is the short area key (e.g. `"aylor"`) that
/// `room.info.zone` and `rooms.area` reference; `name` is the display name.
public struct Area: Sendable, Equatable, Identifiable {
    public var uid: String
    public var name: String?
    /// ANSI/RGB colour code string, as the mapper stores it.
    public var color: String?
    public var texture: String?
    /// Space/comma-separated flags; `"virtual"` marks transient zones.
    public var flags: String

    public var id: String {
        uid
    }

    /// True for transient "virtual" areas the mapper purges on exit.
    public var isVirtual: Bool {
        flags.contains("virtual")
    }

    public init(
        uid: String,
        name: String? = nil,
        color: String? = nil,
        texture: String? = nil,
        flags: String = ""
    ) {
        self.uid = uid
        self.name = name
        self.color = color
        self.texture = texture
        self.flags = flags
    }
}

/// The in-memory map: every room + area keyed by uid. The ``Mapper`` loads
/// this from the ``MapperStore`` on connect and keeps it warm for fast
/// pathfinding and rendering, writing changes through to the store.
///
/// Pure value type — the pathfinder and layout operate on it without
/// touching SQLite, keeping them unit-testable.
public struct RoomGraph: Sendable, Equatable {
    public var rooms: [String: Room]
    public var areas: [String: Area]

    public init(rooms: [String: Room] = [:], areas: [String: Area] = [:]) {
        self.rooms = rooms
        self.areas = areas
    }

    public subscript(uid: String) -> Room? {
        get { rooms[uid] }
        set { rooms[uid] = newValue }
    }

    /// Pseudo-room uid for "from-anywhere" portal exits.
    public static let portalUID = "*"
    /// Pseudo-room uid for "from-anywhere" recall exits.
    public static let recallUID = "**"
}
