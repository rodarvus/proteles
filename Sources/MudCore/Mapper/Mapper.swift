import Foundation

/// The live map: an in-memory ``RoomGraph`` kept warm for pathfinding and
/// rendering, fed by Aardwolf GMCP and written through to a ``MapperStore``
/// (PLAN.md §7.7). A faithful native port of `aard_GMCP_mapper`'s ingestion:
///
///   - `room.info` upserts the current room + its exits (the MUD supplies
///     destination vnums, so links are explicit — no inference). Unmappable
///     rooms (`num == -1`) get a synthetic `nomap_<name>_<area>` uid.
///   - `room.area` upserts the area (name/colour/flags); a room's area key
///     is `room.info.zone`, which equals `room.area.id`.
///   - `room.sectors` refreshes the terrain/environment colour table.
///
/// ``ingest(package:json:)`` returns any follow-up GMCP packets the host
/// should send (e.g. `"request area"` when a room's area name isn't known
/// yet), keeping the actor free of networking.
public actor Mapper {
    private let store: MapperStore
    public private(set) var graph: RoomGraph
    /// The uid of the room the player is currently in (nil until known).
    public private(set) var currentRoomUID: String?
    /// Terrain environment code → name, and terrain name → packed colour,
    /// from `room.sectors` (used by the map panel's colouring).
    public private(set) var environments: [String: String] = [:]
    public private(set) var terrainColours: [String: Int] = [:]

    /// Areas we've already requested, so we don't spam `request area`.
    private var requestedAreas: Set<String> = []

    public init(store: MapperStore) throws {
        self.store = store
        graph = try store.loadGraph()
    }

    /// Feed one GMCP message. Returns GMCP packet payloads to send back
    /// (e.g. `"request area"`), or `[]`.
    @discardableResult
    public func ingest(package: String, json: String) -> [String] {
        switch package.lowercased() {
        case "room.info": return ingestRoomInfo(json)
        case "room.area": ingestArea(json); return []
        case "room.sectors": ingestSectors(json); return []
        default: return []
        }
    }

    // MARK: - room.info

    private func ingestRoomInfo(_ json: String) -> [String] {
        guard let info = try? JSONDecoder().decode(RoomInfo.self, from: Data(json.utf8)) else {
            return []
        }
        let uid = Self.uid(for: info)
        currentRoomUID = uid

        // Exits: dir → destination vnum (string). Preserve any existing
        // per-exit metadata (level/weight/door) when the destination is
        // unchanged, matching the original's lock preservation.
        var exits: [String: Exit] = [:]
        let existing = graph[uid]
        for (dir, dest) in info.exits ?? [:] {
            var exit = Exit(dir: dir, to: String(dest))
            if let old = existing?.exits[dir], old.to == exit.to {
                exit.level = old.level
                exit.weight = old.weight
                exit.door = old.door
            }
            exits[dir] = exit
        }

        var room = Room(
            uid: uid,
            name: AardwolfColor.stripped(info.name),
            area: info.zone,
            terrain: info.terrain,
            info: info.details,
            x: info.coord?.x,
            y: info.coord?.y,
            z: 0,
            exits: exits
        )
        // Carry forward player-set state the GMCP doesn't supply.
        if let existing {
            room.notes = existing.notes
            room.noportal = existing.noportal
            room.norecall = existing.norecall
            room.ignoreExitsMismatch = existing.ignoreExitsMismatch
        }

        let changed = existing == nil || !Self.sameRoom(existing!, room)
        graph[uid] = room
        if changed {
            try? store.upsert(room)
            try? store.saveExits(from: uid, exits: exits)
        }

        // Ensure the area exists; request its details when the name is unknown.
        var requests: [String] = []
        if let zone = info.zone, !zone.isEmpty {
            if graph.areas[zone] == nil {
                let stub = Area(uid: zone)
                graph.areas[zone] = stub
                try? store.upsert(stub)
            }
            if graph.areas[zone]?.name == nil, !requestedAreas.contains(zone) {
                requestedAreas.insert(zone)
                requests.append("request area")
            }
        }
        return requests
    }

    /// The room uid: the vnum as a string, or a synthetic id for unmappable
    /// (`num == -1`) rooms (matching `nomap_<name>_<area>`).
    static func uid(for info: RoomInfo) -> String {
        if info.num == -1 {
            return "nomap_\(info.name)_\(info.zone ?? "")"
        }
        return String(info.num)
    }

    /// Whether two rooms are equivalent for change-detection (name, terrain,
    /// info, area, and the exit dir→destination map) — mirrors the original's
    /// re-save trigger.
    static func sameRoom(_ lhs: Room, _ rhs: Room) -> Bool {
        guard lhs.name == rhs.name, lhs.terrain == rhs.terrain,
              lhs.info == rhs.info, lhs.area == rhs.area,
              lhs.exits.count == rhs.exits.count
        else { return false }
        for (dir, exit) in lhs.exits where rhs.exits[dir]?.to != exit.to {
            return false
        }
        return true
    }

    // MARK: - room.area / room.sectors

    private struct AreaPayload: Decodable {
        let id: String?
        let name: String?
        let texture: String?
        let col: String?
        let flags: String?
    }

    private func ingestArea(_ json: String) {
        guard let payload = try? JSONDecoder().decode(AreaPayload.self, from: Data(json.utf8)),
              let uid = payload.id, !uid.isEmpty
        else { return }
        let area = Area(
            uid: uid,
            name: payload.name,
            color: payload.col,
            texture: payload.texture,
            flags: payload.flags ?? ""
        )
        graph.areas[uid] = area
        try? store.upsert(area)
    }

    private struct SectorsPayload: Decodable {
        struct Sector: Decodable {
            let id: Int?
            let name: String?
            let color: Int?
        }

        let sectors: [Sector]?
    }

    private func ingestSectors(_ json: String) {
        guard let payload = try? JSONDecoder().decode(SectorsPayload.self, from: Data(json.utf8)),
              let sectors = payload.sectors
        else { return }
        environments.removeAll()
        terrainColours.removeAll()
        var rows: [MapperStore.Environment] = []
        for sector in sectors {
            guard let id = sector.id else { continue }
            let key = String(id)
            environments[key] = sector.name
            if let name = sector.name, let color = sector.color { terrainColours[name] = color }
            rows.append(MapperStore.Environment(uid: key, name: sector.name, color: sector.color))
        }
        try? store.replaceEnvironments(rows)
    }

    // MARK: - Lifecycle

    /// Reload the in-memory graph from the store (e.g. after an import).
    public func reload() throws {
        graph = try store.loadGraph()
    }
}
