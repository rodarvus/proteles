import Foundation

/// The live map: an in-memory ``RoomGraph`` kept warm for pathfinding and
/// rendering, fed by Aardwolf GMCP and written through to a ``MapperStore``
/// (PLAN.md §7.7). An independent Swift implementation of Aardwolf's GMCP
/// mapping protocol (`room.info`/`room.area`/`room.sectors`); it reads/writes
/// the same on-disk DB format for compatibility with `aard_GMCP_mapper`:
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
    let store: MapperStore
    public internal(set) var graph: RoomGraph
    /// The uid of the room the player is currently in (nil until known).
    public private(set) var currentRoomUID: String?

    /// In-progress speedwalk, sent segment-by-segment. Rather than firing every
    /// segment at once (which races a portal hop against the follow-on `run` —
    /// the post-portal `run` reached the MUD before the whoosh landed, so it
    /// walked from the wrong room and aborted), we send one segment, then wait
    /// for the destination `room.info` before sending the next. ``walkSegments``
    /// is the full plan, ``walkIndex`` the segment we last sent, ``walkExpect``
    /// the uid we're waiting to arrive in before sending the next (nil = no walk
    /// pending / the final segment is in flight). Internal (not private) so the
    /// `Mapper+Commands` extension's `route` can arm them.
    var walkSegments: [Speedwalk.Segment] = []
    var walkIndex = 0
    var walkExpect: String?

    /// The last room a `goto`/`walkto`/`where` targeted — `mapper resume` re-runs
    /// to it (reference `last_speedwalk_uid`/`last_hyperlink_uid`).
    var lastSpeedwalkTarget: String?
    /// The most recent `find`/`list` result (room uids) + a cursor, so
    /// `mapper next [#]` walks through them (reference `last_result_list`).
    var lastResultList: [String] = []
    var lastResultIndex = 0

    /// The armed token for a two-step destructive confirm (reference
    /// `toConfirm`): set by `mapper purge …` (and later `set database …`),
    /// consumed by the matching `… confirm`.
    var pendingConfirm: String?

    /// The designated bounce portal / recall use-commands (reference
    /// `bounce_portal`/`bounce_recall`): the portal used to bounce out of
    /// norecall/noportal rooms, set by `mapper bounceportal`/`bouncerecall <#>`.
    var bouncePortalDir: String?
    var bounceRecallDir: String?

    /// On a `room.info`, advance a pending segmented walk. If we've arrived in the
    /// room the last-sent segment was heading to, send the next segment;
    /// otherwise (still en route, or no walk) do nothing. This is what makes a
    /// portal hop wait for its whoosh before the follow-on `run` is sent.
    /// Returns the command(s) to execute now.
    public func advanceWalk() -> [ScriptEffect] {
        guard let expect = walkExpect, currentRoomUID == expect else { return [] }
        walkIndex += 1
        guard walkIndex < walkSegments.count else {
            walkExpect = nil
            return []
        }
        let segment = walkSegments[walkIndex]
        // Wait for this segment only if more follow; the last one needs no wait.
        walkExpect = walkIndex < walkSegments.count - 1 ? segment.expectUID : nil
        return [.execute(segment.command)]
    }

    /// Cancel any in-progress segmented walk (a new route supersedes the old).
    func clearWalk() {
        walkSegments = []
        walkIndex = 0
        walkExpect = nil
    }

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

    /// A `mapper cexit <dir>` in progress: the room we left + the command used.
    /// Resolved by sampling the current room after ``cexitDelaySeconds`` (the
    /// reference's run-and-sample custom_exit, BASE_CEXIT_DELAY = 2). The
    /// generation token lets a later cexit supersede a still-pending one.
    var pendingCexit: (from: String, dir: String)?
    private var cexitGeneration = 0

    /// How long to wait for a custom-exit move to land before sampling the
    /// destination room (reference BASE_CEXIT_DELAY).
    static let cexitDelaySeconds = 2

    /// A one-shot override of the cexit delay set by `mapper cexit_wait <n>`
    /// (reference `temp_cexit_delay`), consumed by the next `mapper cexit`.
    var tempCexitDelay: Int?

    /// Subscribers to one-off system notes the mapper pushes outside the GMCP
    /// flow (e.g. a delayed cexit confirmation/failure). The session echoes
    /// these to the output view.
    private var noteSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    /// Subscribe to mapper system notes. The session drains this and echoes
    /// each note; no backfill.
    public func subscribeNotes() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        noteSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNoteSubscriber(id) }
        }
        return stream
    }

    private func removeNoteSubscriber(_ id: UUID) {
        noteSubscribers[id] = nil
    }

    /// Push a system note to subscribers (the session echoes it).
    func emitNote(_ text: String) {
        for continuation in noteSubscribers.values {
            continuation.yield(text)
        }
    }

    /// Forget the current room (`mapper reset`/resetaard); the next room.info
    /// re-establishes position.
    func clearCurrentRoom() {
        currentRoomUID = nil
    }

    /// Arm the timed sampling for an in-flight `mapper cexit`. Returns the
    /// generation so the caller can schedule the finalize.
    func beginPendingCexit(from: String, dir: String) -> Int {
        cexitGeneration += 1
        pendingCexit = (from: from, dir: dir)
        return cexitGeneration
    }

    /// Sample the current room ``cexitDelaySeconds`` after a `mapper cexit`:
    /// if we moved to a new mappable room, the link is CONFIRMED and stored;
    /// otherwise it FAILED. Mirrors the reference's wait-then-sample. A stale
    /// generation (a newer cexit started) is ignored.
    func finalizeCexit(generation: Int) {
        guard generation == cexitGeneration, let pending = pendingCexit else { return }
        pendingCexit = nil
        guard let dest = currentRoomUID else {
            emitNote("CEXIT FAILED: Need to know where we ended up.")
            return
        }
        if dest == "-1" {
            emitNote("CEXIT FAILED: You cannot link custom exits to unmappable rooms.")
            return
        }
        if dest == pending.from {
            emitNote("CEXIT FAILED: Custom Exit \(pending.dir) leads back here!")
            return
        }
        try? store.addCustomExit(dir: pending.dir, from: pending.from, to: dest, level: 0)
        if var room = graph[pending.from] {
            room.exits[pending.dir] = Exit(dir: pending.dir, to: dest)
            graph[pending.from] = room
        }
        reloadGraphAndPublish()
        emitNote("Custom Exit CONFIRMED: \(pending.from) (\(pending.dir)) -> \(dest)")
    }

    /// Layout subscribers (the map panel). Each gets a fresh ``MapLayout``
    /// whenever the current room, graph, or area colours change.
    private var layoutSubscribers: [UUID: AsyncStream<MapLayout>.Continuation] = [:]

    public init(store: MapperStore) throws {
        self.store = store
        graph = try store.loadGraph()
        // Seed the sector palette from disk so imported rooms colour without a
        // live GMCP room.sectors. Inlined (an actor init can't call an isolated
        // method); the merge logic is shared via the static loader.
        let palette = Self.loadPalette(from: store)
        environments = palette.environments
        terrainColours = palette.colours
        // Restore persisted UI preferences (per-profile, in proteles_meta).
        showOtherAreas = Self.persistedFlag(store, Self.showOtherAreasKey)
        showAreaExits = Self.persistedFlag(store, Self.showAreaExitsKey)
        pkBlink = Self.persistedFlag(store, Self.pkBlinkKey, default: true)
        showNotes = Self.persistedFlag(store, Self.showNotesKey, default: true)
        useTextures = Self.persistedFlag(store, Self.useTexturesKey, default: true)
        scanDepth = Self.persistedInt(store, Self.scanDepthKey, default: Self.defaultScanDepth)
        // Restore the designated bounce portal/recall (reference `storage` rows),
        // so they survive a restart / world reload.
        bouncePortalDir = (try? store.storageValue(Self.bouncePortalKey)).flatMap(\.self)
        bounceRecallDir = (try? store.storageValue(Self.bounceRecallKey)).flatMap(\.self)
    }

    /// `storage` row names for the bounce designations (reference parity).
    static let bouncePortalKey = "bounce_portal"
    static let bounceRecallKey = "bounce_recall"

    static let showOtherAreasKey = "ui.show_other_areas"
    static let showAreaExitsKey = "ui.show_area_exits"
    static let pkBlinkKey = "ui.pk_blink"
    static let showNotesKey = "ui.show_notes"
    static let scanDepthKey = "ui.scan_depth"
    static let useTexturesKey = "ui.use_textures"

    /// Default + clamp range for the scan depth (rooms drawn outward).
    public static let defaultScanDepth = 600
    static let scanDepthRange = 50...5000

    /// Read a persisted boolean preference (`"1"` = true).
    private static func persistedFlag(
        _ store: MapperStore,
        _ key: String,
        default def: Bool = false
    ) -> Bool {
        guard let value = try? store.meta(forKey: key) else { return def }
        return value == "1"
    }

    /// Read a persisted integer preference.
    private static func persistedInt(_ store: MapperStore, _ key: String, default def: Int) -> Int {
        guard let value = try? store.meta(forKey: key), let number = Int(value) else { return def }
        return number
    }

    /// Whether neighbouring areas render inline (vs. cross-area exits drawn as
    /// stubs). Defaults off, matching the Aardwolf mapper's `show_other_areas`
    /// default — each area reads as a self-contained map. Toggled from the UI.
    public internal(set) var showOtherAreas = false

    /// Whether to mark exits that leave the current area with a boundary
    /// marker (Aardwolf's `SHOW_AREA_EXITS`, default off). Toggled from the UI.
    public internal(set) var showAreaExits = false

    /// Whether the PK warning animates (Aardwolf's `BLINK_PK_TITLE`, default
    /// on). The PK indicator itself stays regardless.
    public internal(set) var pkBlink = true

    /// Whether a room's player note is echoed on arrival (Aardwolf's
    /// `shownotes`, default on). Toggled by `mapper shownotes [on|off]`.
    public internal(set) var showNotes = true

    /// Whether the current area's background texture tiles behind the map
    /// (Aardwolf's `USE_TEXTURES`, default on like the reference). With no
    /// files in `~/Documents/Proteles/MapImages/` this is a no-op — Proteles
    /// ships no textures (#11).
    public internal(set) var useTextures = true

    /// How many rooms the fan-out BFS draws outward (Aardwolf's scan depth).
    public internal(set) var scanDepth = Mapper.defaultScanDepth

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
            maxDepth: scanDepth,
            maxRooms: scanDepth,
            showOtherAreas: showOtherAreas,
            showAreaExits: showAreaExits,
            pkBlink: pkBlink,
            useTextures: useTextures,
            terrainColours: terrainColours,
            environments: environments
        )
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
    func publishLayout() {
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

    /// Build a room's exit set from a GMCP `room.info`. Compass exits come from
    /// GMCP (preserving per-exit metadata — level/weight/door — when a dir's
    /// destination is unchanged, matching the original's lock preservation).
    /// Existing custom (non-compass) exits are CARRIED FORWARD: GMCP never
    /// reports them, and `saveExits` delete-then-inserts, so without this a
    /// revisit would wipe every player-added `open …`/`say …`/`enter …` exit.
    /// The reference mapper's `save_room_exits` likewise only upserts GMCP dirs
    /// and never deletes custom exits (aard_GMCP_mapper.xml).
    private static func mergedExits(gmcp: [String: Int]?, existing: Room?) -> [String: Exit] {
        var exits: [String: Exit] = [:]
        for (dir, dest) in gmcp ?? [:] {
            var exit = Exit(dir: dir, to: String(dest))
            if let old = existing?.exits[dir], old.to == exit.to {
                exit.level = old.level
                exit.weight = old.weight
                exit.door = old.door
            }
            exits[dir] = exit
        }
        for (dir, exit) in existing?.exits ?? [:] {
            guard !RichExits.isCardinalDirection(dir), exits[dir] == nil else { continue }
            exits[dir] = exit
        }
        return exits
    }

    private func ingestRoomInfo(_ json: String) -> [String] {
        guard let info = try? JSONDecoder().decode(RoomInfo.self, from: Data(json.utf8)) else {
            return []
        }
        let uid = Self.uid(for: info)
        let previousRoomUID = currentRoomUID
        currentRoomUID = uid

        let existing = graph[uid]
        let exits = Self.mergedExits(gmcp: info.exits, existing: existing)

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

        // Surface a room's player note on arrival, like the reference's
        // `*** MAPPER NOTE ***` (got_gmcp_room, shownotes default on). Only on
        // a genuine room change, so standing still / re-looking doesn't repeat.
        if showNotes, previousRoomUID != uid, let note = room.notes, !note.isEmpty {
            emitNote("*** MAPPER NOTE *** : \(note)")
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

    /// Merge the persisted sector palette into the in-memory `environments`
    /// (id→name) + `terrainColours` (name→colour), so rooms colour from disk
    /// without waiting for a live GMCP `room.sectors` (a later `room.sectors`
    /// clears + rebuilds these, staying authoritative when present). This is
    /// what lets an imported map (e.g. all of aylor) render in colour rather
    /// than a uniform grey.
    private func seedTerrainPaletteFromStore() {
        let palette = Self.loadPalette(from: store)
        environments.merge(palette.environments) { _, new in new }
        terrainColours.merge(palette.colours) { _, new in new }
    }

    /// Read the persisted `environments` table into a `(id→name, name→colour)`
    /// pair. `nonisolated` so the actor's `init` can use it before isolation is
    /// established (`MapperStore` access is synchronous + thread-safe).
    private nonisolated static func loadPalette(
        from store: MapperStore
    ) -> (environments: [String: String], colours: [String: Int]) {
        guard let rows = try? store.loadEnvironments() else { return ([:], [:]) }
        var environments: [String: String] = [:]
        var colours: [String: Int] = [:]
        for env in rows {
            guard let name = env.name else { continue }
            environments[env.uid] = name
            if let color = env.color { colours[name] = color }
        }
        return (environments, colours)
    }

    static func decodeInt(_ json: String, key: String) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? Double { return Int(value) }
        if let value = object[key] as? String { return Int(value) }
        return nil
    }

    // MARK: - Lifecycle

    /// Incrementally import another mapper database (adds rooms/areas/exits/
    /// notes we don't already have, never overwriting local data), then
    /// reload the in-memory graph and republish the layout. Returns the
    /// per-table counts of what was added.
    public func importMap(from source: URL) throws -> MapperStore.ImportSummary {
        let summary = try store.importIncremental(from: source)
        graph = try store.loadGraph()
        seedTerrainPaletteFromStore() // an imported DB brings its own sector palette
        publishLayout()
        return summary
    }

    /// Reload the in-memory graph from the store (e.g. after an import).
    public func reload() throws {
        graph = try store.loadGraph()
        seedTerrainPaletteFromStore()
        publishLayout()
    }

    /// Empty the map database (development/testing), then reload the now-empty
    /// graph and forget the current room so the next `room.info` re-establishes
    /// position. UI preferences (scan depth, toggles) are preserved.
    public func emptyDatabase() throws {
        try store.empty()
        clearCurrentRoom()
        graph = try store.loadGraph()
        publishLayout()
    }
}
