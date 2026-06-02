import Foundation

/// The `mapper …` command surface (goto/walkto/where/find/thisroom/
/// unmapped/area/notes/depth/blink), split out of the Mapper actor to keep
/// its body within the type-length budget. Mirrors `aard_GMCP_mapper`'s command
/// names so the muscle memory carries over (the implementation is our own).
extension Mapper {
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
        case "goto": return resolveAndRoute(arg, allowPortals: true)
        case "walkto": return resolveAndRoute(arg, allowPortals: false)
        case "where": return whereRoom(arg)
        case "find": return find(arg)
        case "list": return listSearch(arg)
        case "", "help": return helpOutput(arg)
        default:
            if let nav = handleNavigationCommand(sub, arg) { return nav }
            return handleSecondaryCommand(sub, arg)
        }
    }

    /// The remaining navigation/path verbs (`findpath`/`resume`/`stop`/`next`),
    /// split out of ``handleCommand`` to keep its dispatch within the complexity
    /// budget. Returns `nil` for anything it doesn't own.
    private func handleNavigationCommand(_ sub: String, _ arg: String) -> [ScriptEffect]? {
        switch sub {
        case "findpath": findPathCommand(arg)
        case "resume": resumeCommand()
        case "stop": stopCommand()
        case "next": nextCommand(arg)
        default: nil
        }
    }

    /// Resolve a `goto`/`walkto`/`where` argument to a room: an exact room uid,
    /// a unique room-name match, or (for an ambiguous/no match) the candidate
    /// list. Mirrors the reference mapper, where `find`/`goto` accept a name.
    enum RoomResolution {
        case uid(String)
        case matches([Room])
    }

    func resolveRoom(_ arg: String) -> RoomResolution {
        if graph.rooms[arg] != nil { return .uid(arg) }
        let needle = arg.lowercased()
        let matches = graph.rooms.values
            .filter { !$0.uid.hasPrefix("*") && $0.name.lowercased().contains(needle) }
            .sorted { $0.uid < $1.uid }
        return matches.count == 1 ? .uid(matches[0].uid) : .matches(Array(matches.prefix(20)))
    }

    /// Aardwolf room uids are numeric (portal pseudo-rooms are `*`/`**`), so an
    /// all-digit argument is a room id to route to directly; anything else is a
    /// name to resolve.
    func looksLikeRoomID(_ arg: String) -> Bool {
        !arg.isEmpty && arg.allSatisfy(\.isNumber)
    }

    private func resolveAndRoute(_ arg: String, allowPortals: Bool) -> [ScriptEffect] {
        let verb = allowPortals ? "goto" : "walkto"
        // Reference wording (goto/walkto are room-id-first); we keep name
        // resolution below as a superset.
        guard !arg.isEmpty else {
            return [Self.note("The mapper \(verb) command expects a room id as input.")]
        }
        if looksLikeRoomID(arg) { return route(to: arg, allowPortals: allowPortals) }
        switch resolveRoom(arg) {
        case .uid(let uid):
            return route(to: uid, allowPortals: allowPortals)
        case .matches(let rooms) where rooms.isEmpty:
            return [Self.note("No room matching '\(arg)'. Try 'mapper find <text>'.")]
        case .matches(let rooms):
            var effects = [Self.note("Multiple rooms match '\(arg)' — \(verb) one by id:")]
            for room in rooms {
                effects.append(Self.note("  [\(room.uid)] \(room.name) — \(areaName(room.area))"))
            }
            return effects
        }
    }

    /// Notes/bookmarks + view-config subcommands, split out of
    /// ``handleCommand(_:)`` to keep each within the complexity budget.
    private func handleSecondaryCommand(_ sub: String, _ arg: String) -> [ScriptEffect] {
        switch sub {
        case "note", "addnote": return addNoteCommand(arg)
        case "notes", "bookmarks": return listNotes(arg)
        case "shownotes": return showNotesCommand(arg)
        case "thisroom": return thisRoom()
        case "depth": return depthCommand(arg)
        case "blink": return blinkCommand(arg)
        default:
            if let search = handleSearchCommand(sub, arg) { return search }
            if let display = handleDisplayCommand(sub, arg) { return display }
            if let database = handleDatabaseCommand(sub, arg) { return database }
            return handleMapManagementCommand(sub, arg)
        }
    }

    /// The search-family secondary commands (`areas`/`area`/`unmapped` + the
    /// `shops`/`train`/`quest`/`heal` special searches), split out of
    /// ``handleSecondaryCommand`` to keep its dispatch within the
    /// complexity budget. Returns `nil` for anything it doesn't own.
    private func handleSearchCommand(_ sub: String, _ arg: String) -> [ScriptEffect]? {
        switch sub {
        case "areas": areasTable(arg)
        case "area": areaCommand(arg)
        case "unmapped": unmappedExits(arg)
        case "shops": specialSearch(["shop", "bank"], area: arg)
        case "train": specialSearch(["trainer"], area: arg)
        case "quest": specialSearch(["questor"], area: arg)
        case "heal": specialSearch(["healer"], area: arg)
        default: nil
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
        if path.isEmpty { return [Self.note("You are already in that room.")] }
        lastSpeedwalkTarget = uid
        let name = graph.rooms[uid]?.name ?? "room \(uid)"
        var effects: [ScriptEffect] = [Self.note("Walking to \(name) [\(uid)] — \(path.count) step(s).")]
        // Run each step through the command pipeline (`.execute`), not a raw
        // `.send`: the reference mapper speedwalks via `ExecuteWithWaits`, so a
        // step that's a plugin/alias command — e.g. a portal hop stored as
        // `dinv portal use <id>` — is handled by its plugin instead of leaking
        // to the MUD. Plain directions (`run 3n2e`) match no alias and pass through.
        //
        // Send ONLY the first segment now; the rest are armed as a pending walk
        // and released one at a time as each destination `room.info` arrives
        // (``advanceWalk``). Firing them all at once raced a portal hop against
        // the follow-on `run` (the run reached the MUD before the whoosh, walked
        // from the wrong room, and aborted) — the reference mapper waits between
        // steps for exactly this reason.
        clearWalk()
        let segments = Speedwalk.segments(path)
        walkSegments = segments
        walkIndex = 0
        walkExpect = segments.count > 1 ? segments.first?.expectUID : nil
        if let first = segments.first { effects.append(.execute(first.command)) }
        return effects
    }

    /// `mapper where <room id>` — the path *from where you are now* to the
    /// target, in the reference `printpath` format. Mirrors `aard_GMCP_mapper.xml`
    /// `map_where`: it needs to know your current room, takes a room id (we keep
    /// name resolution as a superset), and rejects same-room.
    private func whereRoom(_ arg: String) -> [ScriptEffect] {
        guard let src = currentRoomUID, graph.rooms[src] != nil else {
            return [Self.note("I don't know where you are right now - try: LOOK")]
        }
        var dest = arg.trimmingCharacters(in: .whitespaces)
        if dest.isEmpty {
            guard let last = lastSpeedwalkTarget else {
                return [Self.note("The mapper where command expects a room id number as input.")]
            }
            dest = last
        } else if !looksLikeRoomID(dest) {
            switch resolveRoom(dest) {
            case .uid(let uid): dest = uid
            case .matches: return find(dest) // name → search (our superset)
            }
        }
        if dest == src { return [Self.note("You are already in that room.")] }
        return printpath(from: src, to: dest)
    }

    /// The reference `printpath(src, dest)` body (aard_GMCP_mapper.xml), emitted
    /// as mapper notes — one note per `\n` in the original format string.
    func printpath(from src: String, to dest: String) -> [ScriptEffect] {
        if src == dest { return [Self.note("Pick different start and end rooms.")] }
        guard graph.rooms[src] != nil else { return [Self.note("Room \(src) not known.")] }
        guard graph.rooms[dest] != nil else { return [Self.note("Room \(dest) not known.")] }
        let options = Pathfinder.Options(level: level, tier: tier)
        guard let path = Pathfinder(graph: graph).path(from: src, to: dest, options: options) else {
            return [Self.note("Path from \(src) to \(dest) not found.")]
        }
        let speedwalk = printpathSpeedwalk(path)
        let header = currentRoomUID != src
            ? "Path from \(src) to \(dest) is:"
            : "Path to \(dest) is:"
        // The reference format ends with "Distance: N\n", so a trailing blank.
        return [Self.note(header), Self.note(speedwalk), Self.note("Distance: \(path.count)"), Self.note("")]
    }

    /// The reference `printpath` speedwalk string: build the compact speedwalk,
    /// then for each `run …` segment space out the letters (screen-reader
    /// friendly, `gsub("%a", "%1 ")`) and join all segments with ` ; `.
    func printpathSpeedwalk(_ path: [PathStep]) -> String {
        Speedwalk.segments(path).map(\.command).map { segment -> String in
            guard segment.hasPrefix("run ") else { return segment }
            let body = segment.dropFirst(4)
            var spaced = ""
            for ch in body {
                spaced += ch.isLetter ? "\(ch) " : String(ch)
            }
            return "run " + spaced.trimmingCharacters(in: .whitespaces)
        }.joined(separator: " ; ")
    }

    /// `mapper findpath <src> <dest>` — same `printpath` format as `where`, but
    /// between two explicit rooms (room ids; names accepted as a superset).
    private func findPathCommand(_ arg: String) -> [ScriptEffect] {
        let parts = arg.split(separator: " ", maxSplits: 1).map { String($0) }
        guard parts.count == 2 else {
            return [Self.note("The mapper findpath command expects two room ids as input.")]
        }
        let resolved = parts.map { token -> String? in
            if looksLikeRoomID(token) { return token }
            if case .uid(let uid) = resolveRoom(token) { return uid }
            return nil
        }
        guard let src = resolved[0] else { return [Self.note("Room \(parts[0]) not known.")] }
        guard let dest = resolved[1] else { return [Self.note("Room \(parts[1]) not known.")] }
        return printpath(from: src, to: dest)
    }

    /// `mapper resume` — re-run to the last goto/walkto/where target (reference
    /// resumes the last speedwalk/hyperlink).
    private func resumeCommand() -> [ScriptEffect] {
        guard let target = lastSpeedwalkTarget else {
            return [Self.note("No outstanding speedwalks or hyperlinks.")]
        }
        return route(to: target, allowPortals: true)
    }

    /// `mapper stop` — cancel an in-flight speedwalk (reference
    /// `cancel_speedwalk`: "Speedwalk cancelled.", silent when nothing pending).
    private func stopCommand() -> [ScriptEffect] {
        let active = walkExpect != nil || !walkSegments.isEmpty
        clearWalk()
        return active ? [Self.note("Speedwalk cancelled.")] : []
    }

    /// `mapper next [#]` — walk the next (or #n) room in the last `find`/`list`
    /// result (reference `do_next`).
    private func nextCommand(_ arg: String) -> [ScriptEffect] {
        let trimmed = arg.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let idx = Int(trimmed) {
            guard idx >= 1, idx <= lastResultList.count else {
                return [Self.note("NEXT ERROR: There is no NEXT result #\(idx).")]
            }
            lastResultIndex = idx
            return route(to: lastResultList[idx - 1], allowPortals: true)
        }
        guard lastResultIndex < lastResultList.count else {
            return [Self.note("NEXT ERROR: No more NEXT results left.")]
        }
        let uid = lastResultList[lastResultIndex]
        lastResultIndex += 1
        return route(to: uid, allowPortals: true)
    }

    /// `mapper depth [rooms]` — show or set how far the map draws.
    private func depthCommand(_ arg: String) -> [ScriptEffect] {
        let trimmed = arg.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return [Self.note("Map scan depth: \(scanDepth) rooms.")]
        }
        guard let value = Int(trimmed) else {
            let range = "\(Self.scanDepthRange.lowerBound)–\(Self.scanDepthRange.upperBound)"
            return [Self.note("Usage: mapper depth <rooms> (\(range))")]
        }
        setScanDepth(value)
        return [Self.note("Map scan depth set to \(scanDepth) rooms.")]
    }

    /// `mapper blink [on|off]` — toggle the PK warning animation.
    private func blinkCommand(_ arg: String) -> [ScriptEffect] {
        switch arg.lowercased() {
        case "on": setPKBlink(true); return [Self.note("PK warning blink: on.")]
        case "off": setPKBlink(false); return [Self.note("PK warning blink: off.")]
        case "": return [Self
                .note("PK warning blink is \(pkBlink ? "on" : "off"). Use 'mapper blink on|off'.")]
        default: return [Self.note("Usage: mapper blink on|off")]
        }
    }

    /// `mapper shownotes [on|off]` — toggle echoing a room's note on arrival
    /// (the reference's `shownotes`, default on).
    private func showNotesCommand(_ arg: String) -> [ScriptEffect] {
        switch arg.lowercased() {
        case "on": setShowNotes(true); return [Self.note("Mapper notes on arrival: on.")]
        case "off": setShowNotes(false); return [Self.note("Mapper notes on arrival: off.")]
        case "": return [Self.note(
                "Mapper notes on arrival are \(showNotes ? "on" : "off"). "
                    + "Use 'mapper shownotes on|off'."
            )]
        default: return [Self.note("Usage: mapper shownotes on|off")]
        }
    }

    func areaName(_ key: String?) -> String {
        key.flatMap { graph.areas[$0]?.name } ?? key ?? "?"
    }

    /// One row of the `mapper areas` table (area keyword, name, mapped-room count).
    private struct AreaRow { let uid: String; let name: String; let count: Int }

    /// `mapper areas [name]` — the bordered area listing, faithful to the
    /// reference `map_areas`: a leading blank + intro, a `+--+`/header/`+--+`
    /// frame, one right-aligned-keyword / left-aligned-name / right-aligned-count
    /// row per area that contains a mapped room (sorted by area name), the
    /// closing border, and the `Found N areas containing M rooms mapped.` footer.
    /// Rows are plain notes (the reference's `map_areas` rows are `Note`, not
    /// hyperlinks). Distinct from `mapper area [name]` (rooms within an area).
    func areasTable(_ arg: String) -> [ScriptEffect] {
        let filter = arg.trimmingCharacters(in: .whitespaces)
        let lowerFilter = filter.lowercased()

        // Rooms per area (only areas that actually contain a mapped room).
        var counts: [String: Int] = [:]
        for room in graph.rooms.values {
            guard let area = room.area, !area.isEmpty else { continue }
            counts[area, default: 0] += 1
        }
        var areas = counts.keys.compactMap { uid -> AreaRow? in
            let name = graph.areas[uid]?.name ?? ""
            if !filter.isEmpty, !name.lowercased().contains(lowerFilter) { return nil }
            return AreaRow(uid: uid, name: name, count: counts[uid] ?? 0)
        }
        areas.sort { $0.name.lowercased() < $1.name.lowercased() }

        // Literal header from the reference; border computed (== the reference's
        // `hl`, pinned in MapperOutputTests).
        let header = "| keyword    | Area Name                               | Explored |"
        let border = MapperOutput.border([10, 39, 8])
        let intro = filter.isEmpty
            ? "The following areas have been mapped:"
            : "The following areas matching '\(filter)' have been mapped:"

        var effects: [ScriptEffect] = [
            MapperOutput.line(""), MapperOutput.line(intro),
            MapperOutput.line(border), MapperOutput.line(header), MapperOutput.line(border)
        ]
        var total = 0
        for area in areas {
            total += area.count
            effects.append(MapperOutput.line(MapperOutput.row([
                MapperOutput.field(area.uid, 10),
                MapperOutput.field(area.name, 39, leftAlign: true),
                MapperOutput.field(String(area.count), 8)
            ])))
        }
        effects.append(MapperOutput.line(border))
        effects.append(MapperOutput.line("Found \(areas.count) areas containing \(total) rooms mapped."))
        effects.append(MapperOutput.line(""))
        return effects
    }

    /// A mapper note line, in the reference mapper colour (see ``MapperOutput``).
    static func note(_ text: String) -> ScriptEffect {
        MapperOutput.line(text)
    }
}
