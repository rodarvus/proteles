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

    /// Character level/tier, from `char.status`/`char.base`, used to gate
    /// level-locked exits and the portal/recall tier bonus.
    public private(set) var level = 0
    public private(set) var tier = 0

    /// Areas we've already requested, so we don't spam `request area`.
    private var requestedAreas: Set<String> = []

    /// Layout subscribers (the map panel). Each gets a fresh ``MapLayout``
    /// whenever the current room, graph, or area colours change.
    private var layoutSubscribers: [UUID: AsyncStream<MapLayout>.Continuation] = [:]

    public init(store: MapperStore) throws {
        self.store = store
        graph = try store.loadGraph()
    }

    /// Whether neighbouring areas render inline (vs. cross-area exits drawn as
    /// stubs). Defaults off, matching the Aardwolf mapper's `show_other_areas`
    /// default — each area reads as a self-contained map. Toggled from the UI.
    public private(set) var showOtherAreas = false

    // MARK: - Layout publishing

    /// The current map laid out around the player (empty until a room is
    /// known) — the UI reads this for backfill before streaming updates.
    public func currentLayout() -> MapLayout {
        guard let uid = currentRoomUID else {
            return MapLayout.build(graph: RoomGraph(), current: "")
        }
        return buildLayout(for: uid)
    }

    /// Build the layout around `uid` with the live terrain palette + the
    /// current `showOtherAreas` setting.
    private func buildLayout(for uid: String) -> MapLayout {
        MapLayout.build(
            graph: graph,
            current: uid,
            showOtherAreas: showOtherAreas,
            terrainColours: terrainColours,
            environments: environments
        )
    }

    /// Toggle whether other areas render inline, then republish the layout.
    public func setShowOtherAreas(_ value: Bool) {
        guard value != showOtherAreas else { return }
        showOtherAreas = value
        publishLayout()
    }

    /// Subscribe to layout updates (no backfill — read ``currentLayout()``
    /// first), mirroring ``MapStore``/``ChatStore``.
    public func subscribeLayout() -> AsyncStream<MapLayout> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MapLayout>.makeStream(bufferingPolicy: .bufferingNewest(1))
        layoutSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLayoutSubscriber(id) }
        }
        return stream
    }

    private func removeLayoutSubscriber(_ id: UUID) {
        layoutSubscribers[id] = nil
    }

    /// Recompute and broadcast the layout to subscribers (called after a room
    /// or area change). No-op when there are no subscribers.
    private func publishLayout() {
        guard !layoutSubscribers.isEmpty, let uid = currentRoomUID else { return }
        let layout = buildLayout(for: uid)
        for continuation in layoutSubscribers.values {
            continuation.yield(layout)
        }
    }

    /// Feed one GMCP message. Returns GMCP packet payloads to send back
    /// (e.g. `"request area"`), or `[]`.
    @discardableResult
    public func ingest(package: String, json: String) -> [String] {
        switch package.lowercased() {
        case "room.info": return ingestRoomInfo(json)
        case "room.area": ingestArea(json); return []
        case "room.sectors": ingestSectors(json); return []
        case "char.status":
            if let value = Self.decodeInt(json, key: "level") { level = value }
            return []
        case "char.base":
            if let value = Self.decodeInt(json, key: "tier") { tier = value }
            return []
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
        publishLayout()
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
        publishLayout()
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

    static func decodeInt(_ json: String, key: String) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? Double { return Int(value) }
        if let value = object[key] as? String { return Int(value) }
        return nil
    }

    // MARK: - Commands

    /// Handle a `mapper …` command, returning the effects to apply (sends +
    /// notes). Covers the Search-and-Destroy contract (`goto`/`walkto`/
    /// `where`) plus core search. Returns `[]` if the input isn't a `mapper`
    /// command.
    public func handleCommand(_ input: String) -> [ScriptEffect] {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.first?.lowercased() == "mapper" else { return [] }
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let split = rest.split(separator: " ", maxSplits: 1)
        let sub = split.first.map { $0.lowercased() } ?? ""
        let arg = split.count > 1 ? split[1].trimmingCharacters(in: .whitespaces) : ""

        switch sub {
        case "goto": return route(to: arg, allowPortals: true)
        case "walkto": return route(to: arg, allowPortals: false)
        case "where": return whereRoom(arg)
        case "find", "list": return find(arg)
        case "note", "addnote": return noteCommand(arg)
        case "notes", "bookmarks": return listNotes()
        case "", "help": return helpOutput()
        default: return [Self.note("Unknown mapper command '\(sub)'. Try 'mapper help'.")]
        }
    }

    // MARK: - Notes / bookmarks

    /// Set or clear a room's note (the `bookmarks` table), then republish the
    /// layout so the panel's note marker updates. `uid` defaults to the
    /// current room. Empty `text` clears the note. Called directly by the UI
    /// (note text can contain anything, so it doesn't round-trip a command).
    @discardableResult
    public func setNote(_ text: String, uid: String? = nil) -> Bool {
        guard let target = uid ?? currentRoomUID, var room = graph.rooms[target] else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        room.notes = trimmed.isEmpty ? nil : trimmed
        graph[target] = room
        try? store.setNote(room.notes, uid: target)
        publishLayout()
        return true
    }

    /// `mapper note [text]` — set the current room's note (empty clears it).
    private func noteCommand(_ text: String) -> [ScriptEffect] {
        guard let uid = currentRoomUID, graph.rooms[uid] != nil else {
            return [Self.note("Your current location is unknown.")]
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = setNote(trimmed, uid: uid)
        if trimmed.isEmpty {
            return [Self.note("Cleared the note for this room.")]
        }
        return [Self.note("Noted [\(uid)]: \(trimmed)")]
    }

    /// `mapper notes` / `mapper bookmarks` — list every room that has a note.
    private func listNotes() -> [ScriptEffect] {
        let noted = graph.rooms.values
            .filter { !($0.notes ?? "").isEmpty }
            .sorted { $0.uid < $1.uid }
            .prefix(50)
        guard !noted.isEmpty else { return [Self.note("No room notes yet.")] }
        var effects: [ScriptEffect] = [Self.note("Room notes:")]
        for room in noted {
            effects.append(Self.note("  [\(room.uid)] \(room.name) — \(room.notes ?? "")"))
        }
        return effects
    }

    private func route(to uid: String, allowPortals: Bool) -> [ScriptEffect] {
        let verb = allowPortals ? "goto" : "walkto"
        guard !uid.isEmpty else { return [Self.note("Usage: mapper \(verb) <room>")] }
        guard let src = currentRoomUID else { return [Self.note("Your current location is unknown.")] }
        // Note: we don't require the destination to be a *fully mapped* room.
        // An unvisited room (a known exit's target that we've never entered) is
        // still routable — the path ends with the known exit into it — matching
        // the Aardwolf mapper, which lets you click an unmapped room to walk
        // there. The pathfinder returns nil if it isn't reachable at all.
        let options = Pathfinder.Options(
            level: level, tier: tier, allowPortals: allowPortals, allowRecalls: allowPortals
        )
        guard let path = Pathfinder(graph: graph).path(from: src, to: uid, options: options) else {
            return [Self.note("No route found to \(uid).")]
        }
        if path.isEmpty { return [Self.note("You're already there.")] }
        let name = graph.rooms[uid]?.name ?? "room \(uid)"
        var effects: [ScriptEffect] = [Self.note("Walking to \(name) [\(uid)] — \(path.count) step(s).")]
        effects += Speedwalk.commands(path).map { ScriptEffect.send($0) }
        return effects
    }

    private func whereRoom(_ uid: String) -> [ScriptEffect] {
        guard let target = uid.isEmpty ? currentRoomUID : uid, let room = graph.rooms[target] else {
            return [Self.note("Unknown room.")]
        }
        var line = "Room \(target): \(room.name) — \(areaName(room.area))"
        if let src = currentRoomUID, src != target {
            let options = Pathfinder.Options(level: level, tier: tier)
            if let path = Pathfinder(graph: graph).path(from: src, to: target, options: options) {
                line += " (\(path.count) step(s) away)"
            }
        }
        return [Self.note(line)]
    }

    private func find(_ text: String) -> [ScriptEffect] {
        guard !text.isEmpty else { return [Self.note("Usage: mapper find <text>")] }
        let needle = text.lowercased()
        let matches = graph.rooms.values
            .filter { !$0.uid.hasPrefix("*") && $0.name.lowercased().contains(needle) }
            .sorted { $0.uid < $1.uid }
            .prefix(20)
        guard !matches.isEmpty else { return [Self.note("No rooms matching '\(text)'.")] }
        var effects: [ScriptEffect] = [Self.note("Rooms matching '\(text)':")]
        for room in matches {
            effects.append(Self.note("  [\(room.uid)] \(room.name) — \(areaName(room.area))"))
        }
        return effects
    }

    private func helpOutput() -> [ScriptEffect] {
        [
            "mapper goto <room>   — speedwalk to a room (portals allowed)",
            "mapper walkto <room> — walk to a room (no portals)",
            "mapper where [room]  — show a room and its distance",
            "mapper find <text>   — search rooms by name",
            "mapper note [text]   — note the current room (empty clears it)",
            "mapper notes         — list rooms that have notes"
        ].map { Self.note($0) }
    }

    private func areaName(_ key: String?) -> String {
        key.flatMap { graph.areas[$0]?.name } ?? key ?? "?"
    }

    private static func note(_ text: String) -> ScriptEffect {
        .colourNote([NoteSegment(text: text, foreground: "#7FB0FF")])
    }

    // MARK: - Lifecycle

    /// Reload the in-memory graph from the store (e.g. after an import).
    public func reload() throws {
        graph = try store.loadGraph()
        publishLayout()
    }
}
