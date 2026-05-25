import Foundation

/// The `mapper …` command surface (goto/walkto/where/find/thisroom/
/// unmapped/area/notes/depth/blink), split out of the Mapper actor to keep
/// its body within the type-length budget. Faithful to aard_GMCP_mapper.
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
        case "find", "list": return find(arg)
        case "", "help": return helpOutput()
        default: return handleSecondaryCommand(sub, arg)
        }
    }

    /// Resolve a `goto`/`walkto`/`where` argument to a room: an exact room uid,
    /// a unique room-name match, or (for an ambiguous/no match) the candidate
    /// list. Mirrors the reference mapper, where `find`/`goto` accept a name.
    private enum RoomResolution {
        case uid(String)
        case matches([Room])
    }

    private func resolveRoom(_ arg: String) -> RoomResolution {
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
    private func looksLikeRoomID(_ arg: String) -> Bool {
        !arg.isEmpty && arg.allSatisfy(\.isNumber)
    }

    private func resolveAndRoute(_ arg: String, allowPortals: Bool) -> [ScriptEffect] {
        let verb = allowPortals ? "goto" : "walkto"
        guard !arg.isEmpty else { return [Self.note("Usage: mapper \(verb) <room id or name>")] }
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
        case "note", "addnote": noteCommand(arg)
        case "notes", "bookmarks", "shownotes": listNotes()
        case "thisroom": thisRoom()
        case "unmapped": unmappedExits()
        case "area": areaCommand(arg)
        case "depth": depthCommand(arg)
        case "blink": blinkCommand(arg)
        default: handleMapManagementCommand(sub, arg)
        }
    }

    /// Portals / custom-exit / findpath / purge subcommands, split from
    /// ``handleSecondaryCommand`` to keep each within the complexity budget.
    private func handleMapManagementCommand(_ sub: String, _ arg: String) -> [ScriptEffect] {
        switch sub {
        case "findpath": findPath(arg)
        case "portals": listPortals(arg)
        case "portal": addPortalCommand(arg)
        case "fullportal": fullPortalCommand(arg)
        case "cexits": listCustomExits(arg)
        case "fullcexit": fullCustomExitCommand(arg)
        default: handleMaintenanceCommand(sub, arg)
        }
    }

    /// Purge / delete / cache subcommands, split out to keep the dispatch
    /// within the cyclomatic-complexity budget.
    private func handleMaintenanceCommand(_ sub: String, _ arg: String) -> [ScriptEffect] {
        switch sub {
        case "purgeroom": purgeRoomCommand()
        case "purgezone": purgeZoneCommand(arg)
        case "clearcache": clearCacheCommand()
        case "delete": deleteCommand(arg)
        case "purge": purgeCommand(arg)
        default: [Self.note("Unknown mapper command '\(sub)'. Try 'mapper help'.")]
        }
    }

    // MARK: - Custom exits (cexits)

    /// `mapper cexits [filter|here]` — list custom (non-cardinal) exits.
    private func listCustomExits(_ arg: String) -> [ScriptEffect] {
        let filter = arg.isEmpty ? nil
            : (arg.lowercased() == "here" ? graph.rooms[currentRoomUID ?? ""]?.area : arg)
        let exits = (try? store.customExits(areaFilter: filter)) ?? []
        guard !exits.isEmpty else {
            return [Self.note("No custom exits\(filter.map { " for '\($0)'" } ?? "").")]
        }
        var effects = [Self.note("Custom exits (\(exits.count)):")]
        for exit in exits {
            let room = exit.roomName ?? exit.fromuid
            effects.append(Self.note("  \(room) [\(exit.fromuid)] — \(exit.dir) → [\(exit.touid)]"))
        }
        return effects
    }

    /// `mapper fullcexit {dir} <fromuid> <touid> <level>` — add a custom exit
    /// with explicit endpoints. (The interactive `mapper cexit <dir>`, which
    /// runs the command and samples the room you land in, needs live
    /// room-change detection and lands in a later batch.)
    private func fullCustomExitCommand(_ arg: String) -> [ScriptEffect] {
        let groups = Self.braceGroups(arg)
        let trailing = arg.components(separatedBy: "}").last ?? ""
        let tokens = trailing.split(separator: " ").map(String.init)
        guard let dir = groups.first, tokens.count >= 2 else {
            return [Self.note("Usage: mapper fullcexit {dir} <from-room> <to-room> [level]")]
        }
        let from = tokens[0], to = tokens[1]
        let level = tokens.count > 2 ? (Int(tokens[2]) ?? 0) : 0
        guard graph.rooms[from] != nil || looksLikeRoomID(from),
              graph.rooms[to] != nil || looksLikeRoomID(to)
        else { return [Self.note("Both rooms must be known room ids.")] }
        do {
            try store.addCustomExit(dir: dir, from: from, to: to, level: level)
            reloadGraphAndPublish()
            return [Self.note("Custom exit '\(dir)' from \(from) → \(to) stored.")]
        } catch {
            return [Self.note("Couldn't store that custom exit.")]
        }
    }

    // MARK: - findpath

    /// `mapper findpath <from> <to>` — print the speedwalk + distance between
    /// two rooms without moving (≈ reference `printpath`).
    private func findPath(_ arg: String) -> [ScriptEffect] {
        let parts = arg.split(separator: " ", maxSplits: 1)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let from = resolveUID(parts[0]), let to = resolveUID(parts[1]) else {
            return [Self.note("Usage: mapper findpath <from> <to>  (room ids or unique names)")]
        }
        let options = Pathfinder.Options(level: level, tier: tier)
        guard let path = Pathfinder(graph: graph).path(from: from, to: to, options: options) else {
            return [Self.note("No route from \(from) to \(to).")]
        }
        let speed = path.isEmpty ? "(same room)" : Speedwalk.build(path)
        return [Self.note("\(from) → \(to): \(speed)  — \(path.count) step(s)")]
    }

    /// Resolve a findpath/portal argument: an all-digit room id, or a unique
    /// room-name match.
    private func resolveUID(_ arg: String) -> String? {
        if looksLikeRoomID(arg) { return arg }
        if case .uid(let uid) = resolveRoom(arg) { return uid }
        return nil
    }

    // MARK: - Portals

    /// `mapper portals [filter]` — list portals + recalls (filter by dest area).
    private func listPortals(_ arg: String) -> [ScriptEffect] {
        let filter = arg.isEmpty ? nil
            : (arg.lowercased() == "here" ? graph.rooms[currentRoomUID ?? ""]?.area : arg)
        let portals = (try? store.portals(areaFilter: filter)) ?? []
        guard !portals.isEmpty else {
            return [Self.note("No portals stored\(filter.map { " for '\($0)'" } ?? "").")]
        }
        var effects = [Self.note("Portals (\(portals.count)):")]
        for (index, portal) in portals.enumerated() {
            let kind = portal.isRecall ? "recall" : "portal"
            let lvl = portal.level > 0 ? " L\(portal.level)" : ""
            let dest = portal.roomName ?? "?"
            effects.append(Self.note(
                "  #\(index + 1) [\(kind)] \(portal.dir) → \(dest) [\(portal.touid)]\(lvl)"
            ))
        }
        return effects
    }

    /// `mapper portal <dir> [touid] [level]` — add a portal whose use-command is
    /// <dir>; destination defaults to the current room. A "home"/"recall"
    /// keyword stores it as a recall.
    private func addPortalCommand(_ arg: String) -> [ScriptEffect] {
        let tokens = arg.split(separator: " ").map(String.init)
        guard let dir = tokens.first else {
            return [Self.note("Usage: mapper portal <use-command> [destination-room] [level]")]
        }
        let touid = tokens.count > 1 ? tokens[1] : currentRoomUID
        guard let destination = touid,
              graph.rooms[destination] != nil || looksLikeRoomID(destination)
        else {
            return [Self.note("Unknown destination room (and your current room is unknown).")]
        }
        let level = tokens.count > 2 ? (Int(tokens[2]) ?? 0) : 0
        return storePortal(dir: dir, touid: destination, level: level)
    }

    /// `mapper fullportal {use-command} {destination} <level>`.
    private func fullPortalCommand(_ arg: String) -> [ScriptEffect] {
        let groups = Self.braceGroups(arg)
        guard groups.count >= 2 else {
            return [Self.note("Usage: mapper fullportal {use-command} {destination-room} <level>")]
        }
        let trailing = arg.components(separatedBy: "}").last ?? ""
        let levelToken = trailing.trimmingCharacters(in: .whitespaces).split(separator: " ").first
        let level = Int(levelToken.map(String.init) ?? "") ?? 0
        return storePortal(dir: groups[0], touid: groups[1], level: level)
    }

    private func storePortal(dir: String, touid: String, level: Int) -> [ScriptEffect] {
        let recall = ["home", "hom", "recall"].contains(dir.lowercased())
        do {
            try store.addPortal(dir: dir, touid: touid, level: level, recall: recall)
            reloadGraphAndPublish()
            let kind = recall ? "recall" : "portal"
            let lvl = level > 0 ? " (level \(level))" : ""
            return [Self.note("Stored '\(dir)' as a \(kind) to room \(touid)\(lvl).")]
        } catch {
            return [Self.note("Couldn't store that portal.")]
        }
    }

    // MARK: - delete / purge

    private func deleteCommand(_ arg: String) -> [ScriptEffect] {
        let tokens = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch tokens.first?.lowercased() {
        case "portal":
            let dir = tokens.count > 1 ? tokens[1] : ""
            guard !dir.isEmpty else { return [Self.note("Usage: mapper delete portal <use-command>")] }
            let removed = (try? store.deletePortal(dir: dir)) ?? false
            if removed { reloadGraphAndPublish() }
            return [Self.note(removed ? "Deleted portal '\(dir)'." : "No portal '\(dir)'.")]
        case "cexits":
            guard let uid = currentRoomUID else { return [Self.note("Your current location is unknown.")] }
            let count = (try? store.deleteCustomExits(from: uid)) ?? 0
            if count > 0 { reloadGraphAndPublish() }
            return [Self.note("Deleted \(count) custom exit(s) from room \(uid).")]
        case "exits":
            return deleteExitsCommand(tokens.count > 1 ? tokens[1] : "")
        default:
            return [Self.note(
                "Usage: mapper delete portal <cmd> | delete cexits | delete exits to|from <room>"
            )]
        }
    }

    /// `mapper delete exits to|from <room>` — remove the exits between the
    /// current room and another (reference: to → from current, from → into).
    private func deleteExitsCommand(_ arg: String) -> [ScriptEffect] {
        guard let here = currentRoomUID else { return [Self.note("Your current location is unknown.")] }
        let tokens = arg.split(separator: " ", maxSplits: 1).map(String.init)
        guard tokens.count == 2, let other = resolveUID(tokens[1]) else {
            return [Self.note("Usage: mapper delete exits to|from <room>")]
        }
        let count: Int
        switch tokens[0].lowercased() {
        case "to": count = (try? store.deleteExits(from: here, to: other)) ?? 0
        case "from": count = (try? store.deleteExits(from: other, to: here)) ?? 0
        default: return [Self.note("Usage: mapper delete exits to|from <room>")]
        }
        if count > 0 { reloadGraphAndPublish() }
        return [Self.note("Deleted \(count) exit(s).")]
    }

    private func purgeCommand(_ arg: String) -> [ScriptEffect] {
        let tokens = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch tokens.first?.lowercased() {
        case "portals":
            try? store.purgePortals()
            reloadGraphAndPublish()
            return [Self.note("Purged all portals.")]
        case "cexits":
            let area = tokens.count > 1 ? tokens[1] : nil
            try? store.purgeCustomExits(area: area)
            reloadGraphAndPublish()
            return [Self.note("Purged custom exits\(area.map { " in '\($0)'" } ?? "").")]
        default:
            return [Self.note("Usage: mapper purge portals | purge cexits [area]")]
        }
    }

    private func purgeRoomCommand() -> [ScriptEffect] {
        guard let uid = currentRoomUID else { return [Self.note("Your current location is unknown.")] }
        try? store.purgeRoom(uid: uid)
        reloadGraphAndPublish()
        return [Self.note("Purged room \(uid) from the map.")]
    }

    private func purgeZoneCommand(_ arg: String) -> [ScriptEffect] {
        let area = arg.isEmpty ? graph.rooms[currentRoomUID ?? ""]?.area : arg
        guard let area else { return [Self.note("Usage: mapper purgezone [area]  (or stand in one)")] }
        try? store.purgeZone(area: area)
        reloadGraphAndPublish()
        return [Self.note("Purged area '\(area)' from the map.")]
    }

    private func clearCacheCommand() -> [ScriptEffect] {
        reloadGraphAndPublish()
        return [Self.note("Reloaded the map from the database.")]
    }

    /// Reload the in-memory graph from the store and republish — after a
    /// portal/purge edit so pathfinding + the panel reflect it.
    private func reloadGraphAndPublish() {
        graph = (try? store.loadGraph()) ?? graph
        publishLayout()
    }

    /// Extract `{…}` groups from a command argument (fullportal/fullcexit).
    private static func braceGroups(_ string: String) -> [String] {
        var groups: [String] = []
        var current = ""
        var inBrace = false
        for character in string {
            if character == "{" {
                inBrace = true
                current = ""
            } else if character == "}" {
                inBrace = false
                groups.append(current)
            } else if inBrace {
                current.append(character)
            }
        }
        return groups
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

    private func whereRoom(_ arg: String) -> [ScriptEffect] {
        // No argument → describe the current room (≈ reference `mapper where`).
        if arg.isEmpty {
            guard let uid = currentRoomUID, graph.rooms[uid] != nil else {
                return [Self.note("Your current location is unknown.")]
            }
            return whereRoom(byUID: uid)
        }
        // A room id → that room + its distance; otherwise a name search.
        if looksLikeRoomID(arg) { return whereRoom(byUID: arg) }
        switch resolveRoom(arg) {
        case .uid(let uid): return whereRoom(byUID: uid)
        case .matches: return find(arg)
        }
    }

    private func whereRoom(byUID target: String) -> [ScriptEffect] {
        guard let room = graph.rooms[target] else { return [Self.note("Unknown room \(target).")] }
        var line = "Room \(target): \(room.name) — \(areaName(room.area))"
        if let src = currentRoomUID, src != target {
            let options = Pathfinder.Options(level: level, tier: tier)
            if let path = Pathfinder(graph: graph).path(from: src, to: target, options: options) {
                line += " (\(path.count) step(s) away)"
            }
        }
        return [Self.note(line)]
    }

    /// `mapper thisroom` — details of the room you're standing in.
    private func thisRoom() -> [ScriptEffect] {
        guard let uid = currentRoomUID, let room = graph.rooms[uid] else {
            return [Self.note("Your current location is unknown.")]
        }
        var effects = [Self.note("[\(uid)] \(room.name) — \(areaName(room.area))")]
        let exits = room.exits.keys.sorted().joined(separator: ", ")
        if !exits.isEmpty { effects.append(Self.note("  Exits: \(exits)")) }
        if let terrain = room.terrain, !terrain.isEmpty { effects.append(Self.note("  Terrain: \(terrain)")) }
        if let note = room.notes, !note.isEmpty { effects.append(Self.note("  Note: \(note)")) }
        return effects
    }

    /// `mapper unmapped` — exits from the current room whose destination we
    /// don't have in the database yet (somewhere to explore).
    private func unmappedExits() -> [ScriptEffect] {
        guard let uid = currentRoomUID, let room = graph.rooms[uid] else {
            return [Self.note("Your current location is unknown.")]
        }
        let unknown = room.exits
            .filter { $0.value.to.isEmpty || graph.rooms[$0.value.to] == nil }
            .keys.sorted()
        guard !unknown.isEmpty else { return [Self.note("No unmapped exits from here.")] }
        return [Self.note("Unmapped exits: \(unknown.joined(separator: ", "))")]
    }

    /// `mapper area [name]` — the current area (with room count), or a search
    /// of areas by name (≈ reference `mapper area <name>`).
    private func areaCommand(_ arg: String) -> [ScriptEffect] {
        if arg.isEmpty {
            guard let uid = currentRoomUID, let area = graph.rooms[uid]?.area else {
                return [Self.note("Your current area is unknown.")]
            }
            let count = graph.rooms.values.count { $0.area == area }
            return [Self.note("Area: \(areaName(area)) [\(area)] — \(count) room(s) mapped.")]
        }
        let needle = arg.lowercased()
        let matches = graph.areas.values
            .filter { ($0.name ?? "").lowercased().contains(needle) || $0.uid.lowercased().contains(needle) }
            .sorted { ($0.name ?? $0.uid) < ($1.name ?? $1.uid) }
            .prefix(20)
        guard !matches.isEmpty else { return [Self.note("No area matching '\(arg)'.")] }
        var effects = [Self.note("Areas matching '\(arg)':")]
        for area in matches {
            let count = graph.rooms.values.count { $0.area == area.uid }
            effects.append(Self.note("  [\(area.uid)] \(area.name ?? area.uid) — \(count) room(s)"))
        }
        return effects
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

    private func helpOutput() -> [ScriptEffect] {
        [
            "mapper goto <room|name>  — speedwalk to a room (id or name; portals ok)",
            "mapper walkto <room|name> — walk there without portals",
            "mapper where [room|name]  — current room, a room + distance, or a name search",
            "mapper find <text>        — search rooms by name",
            "mapper thisroom          — details of the room you're in",
            "mapper unmapped          — exits from here with no mapped destination",
            "mapper area [name]       — current area, or search areas by name",
            "mapper note [text]       — note the current room (empty clears it)",
            "mapper notes             — list rooms that have notes",
            "mapper depth [n]         — how many rooms to draw outward",
            "mapper blink [on|off]    — toggle the PK-room warning animation"
        ].map { Self.note($0) }
    }

    private func areaName(_ key: String?) -> String {
        key.flatMap { graph.areas[$0]?.name } ?? key ?? "?"
    }

    private static func note(_ text: String) -> ScriptEffect {
        .colourNote([NoteSegment(text: text, foreground: "#7FB0FF")])
    }
}
