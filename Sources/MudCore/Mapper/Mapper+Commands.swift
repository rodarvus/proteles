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
        case "find", "list": return find(arg)
        case "", "help": return helpOutput()
        default: return handleSecondaryCommand(sub, arg)
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
        case "notes", "bookmarks": listNotes()
        case "shownotes": showNotesCommand(arg)
        case "thisroom": thisRoom()
        case "unmapped": unmappedExits()
        case "area": areaCommand(arg)
        case "depth": depthCommand(arg)
        case "blink": blinkCommand(arg)
        default: handleMapManagementCommand(sub, arg)
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
        // Run each step through the command pipeline (`.execute`), not a raw
        // `.send`: the reference mapper speedwalks via `ExecuteWithWaits`, so a
        // step that's a plugin/alias command — e.g. a portal hop stored as
        // `dinv portal use <id>` — is handled by its plugin instead of leaking
        // to the MUD. Plain directions (`run 3n2e`) match no alias and pass through.
        effects += Speedwalk.commands(path).map { ScriptEffect.execute($0) }
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
            "mapper shownotes [on|off] — echo a room's note on arrival",
            "mapper depth [n]         — how many rooms to draw outward",
            "mapper blink [on|off]    — toggle the PK-room warning animation"
        ].map { Self.note($0) }
    }

    func areaName(_ key: String?) -> String {
        key.flatMap { graph.areas[$0]?.name } ?? key ?? "?"
    }

    static func note(_ text: String) -> ScriptEffect {
        .colourNote([NoteSegment(text: text, foreground: "#7FB0FF")])
    }
}
