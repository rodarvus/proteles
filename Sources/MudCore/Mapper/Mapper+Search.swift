import Foundation

/// Phase 2 of the mapper-fidelity work: the search commands (`find`, `area`,
/// `list`, and — added in a follow-up — the special searches and `unmapped`),
/// rendered byte-faithfully to the reference Aardwolf mapper
/// (`aardmapper.lua` `full_find`/`quick_find`/`find`, `aard_GMCP_mapper.xml`
/// `map_find`/`map_area`/`map_list`).
///
/// The linchpin is ``runFullFind(_:name:maxPaths:)`` — the reference `full_find`:
/// it pathfinds from the current room to every match, sorts closest-first,
/// prints `Found N targets matching '<pattern>'.`, a `START/END OF SEARCH`
/// frame, and one **clickable** `[i] <name> (<area>)` row per reachable room
/// (click → `mapper goto <uid>`) followed by a ` - <distance>` line. `find`,
/// `area`, and the special searches all funnel through it.
extension Mapper {
    /// One search destination: the room uid and an optional reason label (the
    /// reference `{uid=…, reason=…}`). `reason` is shown as ` [<reason>]` after
    /// the distance for special searches; `nil`/empty for plain `find`/`area`.
    struct FindDest {
        let uid: String
        let reason: String?
    }

    /// A reachable search result: the room, its path length (distance), and the
    /// optional reason label carried from the destination.
    private struct FoundEntry {
        let uid: String
        let path: [PathStep]
        let reason: String?

        var dist: Int {
            path.count
        }
    }

    // MARK: - Reference `find`/`area`/`list` aliases

    /// `mapper find <text>` (reference `map_find`): rooms whose name matches
    /// `<text>` (a `%text%` substring, or an exact match when the text is
    /// `"quoted"`), distance-sorted and clickable. `max_paths` is 50.
    func find(_ text: String) -> [ScriptEffect] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [Self.note("The mapper find command expects search text.")] }
        let pattern = Self.likePattern(trimmed)
        let dests = graph.rooms.values
            .filter { !$0.uid.hasPrefix("*") && Self.nameMatches($0.name, pattern: pattern) }
            .sorted { $0.uid < $1.uid }
            .map { FindDest(uid: $0.uid, reason: nil) }
        return runFullFind(dests, name: pattern.display, maxPaths: 50)
    }

    /// `mapper area [text]` (reference `map_area`): rooms in the *current* area
    /// matching `<text>` (all rooms in the area when empty), via `full_find`.
    func areaCommand(_ arg: String) -> [ScriptEffect] {
        guard let current = currentRoomUID else {
            return [Self.note("I do not know your room! Try typing 'LOOK' first.")]
        }
        guard let area = graph.rooms[current]?.area else {
            return [Self
                .note("AREA ERROR: The area has not been initialized yet. Please try again in a second.")]
        }
        let pattern = Self.likePattern(arg.trimmingCharacters(in: .whitespaces))
        let dests = graph.rooms.values
            .filter { $0.area == area && Self.nameMatches($0.name, pattern: pattern) }
            .sorted { $0.uid < $1.uid }
            .map { FindDest(uid: $0.uid, reason: nil) }
        return runFullFind(dests, name: pattern.display, maxPaths: 50)
    }

    /// `mapper list <text>` (reference `map_list`): a plain, non-clickable
    /// `START/END OF SEARCH`-framed listing of matching rooms with their uid and
    /// area keyword, sorted by area, capped at 100 (abort message past that).
    func listSearch(_ text: String) -> [ScriptEffect] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pattern = Self.likePattern(trimmed)
        let matches = graph.rooms.values
            .filter { !$0.uid.hasPrefix("*") && Self.nameMatches($0.name, pattern: pattern) }
            .sorted { ($0.area ?? "", $0.uid) < ($1.area ?? "", $1.uid) }
        var out: [ScriptEffect] = [searchHeader]
        for room in matches.prefix(100) {
            out.append(Self.note("(\(room.uid)) \(room.name) is in area \"\(room.area ?? "<No area>")\""))
        }
        if matches.count > 100 {
            out.append(Self.note(
                "More than 100 search results found. Aborting query. "
                    + "Try a more specific search phrase than '\(trimmed)'."
            ))
        }
        out.append(searchFooter)
        return out
    }

    // MARK: - The shared `full_find` renderer

    /// The reference `find` + `full_find`: emit `Found N targets matching
    /// '<name>'.`, bail with the over-`max_paths` message when there are too
    /// many, then pathfind to each, sort closest-first, and render the
    /// `START/END OF SEARCH` frame with clickable rows (populating
    /// `lastResultList` so `mapper next` can walk them).
    func runFullFind(_ dests: [FindDest], name: String, maxPaths: Int) -> [ScriptEffect] {
        guard let current = currentRoomUID, graph.rooms[current] != nil else {
            return [Self.note("I don't know where you are right now - try: LOOK")]
        }
        var out: [ScriptEffect] = []
        let plural = dests.count != 1 ? "s" : ""
        out.append(Self.note("Found \(dests.count) target\(plural) matching '\(name)'."))
        let limit = maxPaths <= 0 ? dests.count : maxPaths
        if dests.count > limit {
            out.append(Self.note(
                "Your search returned more than \(limit) results. Choose a more specific pattern."
            ))
            return out
        }
        lastResultList = []
        lastResultIndex = 0

        let pathfinder = Pathfinder(graph: graph)
        let options = Pathfinder.Options(level: level, tier: tier)
        var found: [FoundEntry] = []
        var notfound: [FindDest] = []
        for dest in dests {
            if dest.uid == current {
                found.append(FoundEntry(uid: dest.uid, path: [], reason: dest.reason))
            } else if let path = pathfinder.path(from: current, to: dest.uid, options: options) {
                found.append(FoundEntry(uid: dest.uid, path: path, reason: dest.reason))
            } else {
                notfound.append(dest)
            }
        }
        found.sort { $0.dist < $1.dist }

        out.append(contentsOf: mapperBroadcastEffects(for: broadcastTargets(
            found: found,
            notfound: notfound
        )))
        out.append(searchHeader)
        for entry in found {
            out.append(contentsOf: foundRow(entry, current: current))
        }
        out.append(contentsOf: notFoundSection(notfound, foundCount: found.count, expected: dests.count))
        out.append(searchFooter)
        return out
    }

    private func broadcastTargets(
        found: [FoundEntry],
        notfound: [FindDest]
    ) -> [MapperPluginBridge.Target] {
        found.map {
            MapperPluginBridge.Target(
                uid: $0.uid,
                reason: $0.reason,
                genericReason: $0.reason == nil,
                path: $0.path
            )
        } + notfound.map {
            MapperPluginBridge.Target(
                uid: $0.uid,
                reason: $0.reason,
                genericReason: $0.reason == nil,
                path: nil
            )
        }
    }

    /// One reachable-room result: a clickable `[i] <name> (<area>)` row (or a
    /// plain row when it's the room you're in), then ` - <distance>[ reason]`.
    private func foundRow(_ entry: FoundEntry, current: String) -> [ScriptEffect] {
        let room = graph.rooms[entry.uid]
        let area = room?.area ?? "<No area>"
        let roomName = "\(room?.name ?? "Room \(entry.uid)") (\(area))"
        let distance = Self.distancePhrase(entry.dist)
        let info = (entry.reason?.isEmpty == false) ? " [\(entry.reason!)]" : ""
        var rows: [ScriptEffect] = []
        if entry.uid != current {
            lastResultList.append(entry.uid)
            rows.append(MapperOutput.gotoRow(
                "[\(lastResultList.count)] \(roomName)",
                uid: entry.uid,
                hint: "Click to speedwalk there (\(distance))"
            ))
        } else {
            rows.append(Self.note(roomName))
        }
        rows.append(Self.note(" - \(distance)\(info)"))
        return rows
    }

    /// The reference's trailing "could not find a path to within N rooms" block,
    /// emitted only when some matches were unreachable.
    private func notFoundSection(
        _ notfound: [FindDest], foundCount: Int, expected: Int
    ) -> [ScriptEffect] {
        guard foundCount < expected, !notfound.isEmpty else { return [] }
        let diff = expected - foundCount
        let (were, matches) = diff == 1 ? ("was", "match") : ("were", "matches")
        let lead = "There \(were) \(diff) \(matches) which I could not find a path to"
        var rows: [ScriptEffect] = [
            Self.note("+------------------------------------------------------------------------------+"),
            Self.note("\(lead) within \(scanDepth) rooms:")
        ]
        for dest in notfound {
            let room = graph.rooms[dest.uid]
            let line = "\(room?.name ?? "Room \(dest.uid)") (\(room?.area ?? "<No area>"))"
            rows.append(Self.note(line))
            if let reason = dest.reason, !reason.isEmpty {
                rows.append(Self.note(" - [\(reason)]"))
            } else {
                rows.append(Self.note(""))
            }
        }
        return rows
    }

    // MARK: - Shared helpers

    /// The reference distance phrase: `"<N> room[s] away"`, plural when N > 1 or
    /// N == 0 (`#path > 1 or #path == 0`).
    static func distancePhrase(_ count: Int) -> String {
        let plural = (count > 1 || count == 0) ? "s" : ""
        return "\(count) room\(plural) away"
    }

    /// A parsed reference SQL `LIKE` pattern. `display` is the literal string the
    /// reference echoes in "matching '…'" (the `%text%` pattern, % included);
    /// `needle` is what we substring-match on; `exact` is set for a `"quoted"`
    /// (whole-name) match.
    struct LikePattern {
        let display: String
        let needle: String
        let exact: Bool
    }

    /// Parse the reference `LIKE` pattern: `%text%` substring search, or the
    /// inner text verbatim (exact match) when the text is `"quoted"`.
    static func likePattern(_ text: String) -> LikePattern {
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            let inner = String(text.dropFirst().dropLast())
            return LikePattern(display: inner, needle: inner, exact: true)
        }
        return LikePattern(display: "%\(text)%", needle: text, exact: false)
    }

    /// Whether a room name matches a ``likePattern`` (case-insensitive substring,
    /// or exact when the pattern was quoted).
    static func nameMatches(_ roomName: String, pattern: LikePattern) -> Bool {
        if pattern.exact { return roomName.lowercased() == pattern.needle.lowercased() }
        // An empty needle is SQL `%%` — matches everything (Swift's
        // `contains("")` is false, so special-case it).
        if pattern.needle.isEmpty { return true }
        return roomName.lowercased().contains(pattern.needle.lowercased())
    }

    var searchHeader: ScriptEffect {
        Self.note("+------------------------------ START OF SEARCH -------------------------------+")
    }

    var searchFooter: ScriptEffect {
        Self.note("+-------------------------------- END OF SEARCH -------------------------------+")
    }
}

// MARK: - Special searches (shops / trainers / questors / healers)

extension Mapper {
    /// `mapper shops|train|quest|heal [here|<area>]` (reference
    /// `map_find_special`): rooms whose `info` field contains one of `keywords`,
    /// rendered via `quick_find` (clickable, no distance), prefixed by the
    /// reference "Searching …" intro line.
    func specialSearch(_ keywords: [String], area: String) -> [ScriptEffect] {
        let wanted = Set(keywords.map { $0.lowercased() })
        let trimmed = area.trimmingCharacters(in: .whitespaces)
        var out: [ScriptEffect] = []
        let matchesArea: (String?) -> Bool
        if trimmed.isEmpty {
            out.append(Self.note("Searching all areas"))
            matchesArea = { _ in true }
        } else if trimmed.lowercased() == "here" {
            out.append(Self.note("Searching current area"))
            let current = currentRoomUID.flatMap { graph.rooms[$0]?.area }
            matchesArea = { $0 == current }
        } else {
            out.append(Self.note("Searching areas that partially match %\(trimmed)%"))
            let needle = trimmed.lowercased()
            matchesArea = { ($0 ?? "").lowercased().contains(needle) }
        }

        var dests: [FindDest] = []
        for room in graph.rooms.values.sorted(by: { $0.uid < $1.uid }) {
            guard let info = room.info, !info.isEmpty, matchesArea(room.area) else { continue }
            let items = info.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let matched = items.filter { wanted.contains($0.lowercased()) }
            guard !matched.isEmpty else { continue }
            let reason = matched.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ", ")
            dests.append(FindDest(uid: room.uid, reason: reason))
        }
        out.append(contentsOf: runQuickFind(dests, name: keywords.joined(separator: ",")))
        return out
    }

    /// The reference `quick_find`: like `full_find` but with no pathfinding — a
    /// `START/END OF SEARCH` frame, clickable `[i] <name> (<area>)` rows (or a
    /// `[you are here] …` row for the current room), each followed by its
    /// ` -  [reason]` line (or a blank line when there's no reason).
    func runQuickFind(_ dests: [FindDest], name: String) -> [ScriptEffect] {
        guard let current = currentRoomUID, graph.rooms[current] != nil else {
            return [Self.note("I don't know where you are right now - try: LOOK")]
        }
        var out: [ScriptEffect] = []
        let plural = dests.count != 1 ? "s" : ""
        out.append(Self.note("Found \(dests.count) target\(plural) matching '\(name)'."))
        lastResultList = []
        lastResultIndex = 0
        out.append(searchHeader)
        for dest in dests {
            let room = graph.rooms[dest.uid]
            let roomName = "\(room?.name ?? "Room \(dest.uid)") (\(room?.area ?? "<No area>"))"
            if dest.uid != current {
                lastResultList.append(dest.uid)
                out.append(MapperOutput.gotoRow(
                    "[\(lastResultList.count)] \(roomName)", uid: dest.uid, hint: "Click to speedwalk there"
                ))
            } else {
                out.append(Self.note("[you are here] \(roomName)"))
            }
            // Reference: `mapprint(" - " .. " [reason]")` → two spaces; else blank.
            if let reason = dest.reason, !reason.isEmpty {
                out.append(Self.note(" -  [\(reason)]"))
            } else {
                out.append(Self.note(""))
            }
        }
        out.append(searchFooter)
        return out
    }
}

// MARK: - Unmapped exits

extension Mapper {
    /// A `(dir, exit)` of a room counts as *unmapped* when its destination uid is
    /// set (not the empty / `-1` "unknown" sentinel) but that room isn't in the
    /// database yet — somewhere known-of but not yet explored.
    private func unmappedExits(of room: Room) -> [(dir: String, to: String)] {
        room.exits
            .filter { !$0.value.to.isEmpty && $0.value.to != "-1" && graph.rooms[$0.value.to] == nil }
            .map { (dir: $0.key, to: $0.value.to) }
            .sorted { $0.dir < $1.dir }
    }

    /// `mapper unmapped [here|<area>]` (reference `show_known_unmapped_exits`):
    /// with no argument, a bordered by-area count table; with an area (or
    /// `here`), a bordered, clickable per-exit table.
    func unmappedExits(_ arg: String) -> [ScriptEffect] {
        let area = arg.trimmingCharacters(in: .whitespaces)
        if area.isEmpty { return unmappedByArea() }
        if area.lowercased() == "here" {
            guard let current = currentRoomUID, let here = graph.rooms[current]?.area else {
                return [Self.note(
                    "UNMAPPED HERE ERROR: The mapper doesn't know where you are. Type 'LOOK' and try again."
                )]
            }
            return unmappedByRoom(
                intro: "The following rooms in the current area have unmapped exits:",
                matchesArea: { $0?.lowercased() == here.lowercased() }
            )
        }
        let needle = area.lowercased()
        return unmappedByRoom(
            intro: "The following rooms in areas matching '\(area)' have unmapped exits:",
            matchesArea: { ($0 ?? "").lowercased().contains(needle) }
        )
    }

    /// The no-argument by-area count table.
    private func unmappedByArea() -> [ScriptEffect] {
        var counts: [String: Int] = [:]
        for room in graph.rooms.values where !room.uid.hasPrefix("*") {
            let n = unmappedExits(of: room).count
            if n > 0 { counts[room.area ?? "<No area>", default: 0] += n }
        }
        let border = MapperOutput.border([10, 5])
        var out: [ScriptEffect] = [
            Self.note(""),
            Self.note("The following areas have unmapped exits:"),
            Self.note(border),
            Self.note("| area       | count |"),
            Self.note(border)
        ]
        var total = 0
        for key in counts.keys.sorted() {
            let count = counts[key] ?? 0
            total += count
            out.append(Self.note(MapperOutput.row([
                MapperOutput.field(key, 10), MapperOutput.field(String(count), 5)
            ])))
        }
        out.append(Self.note(border))
        out.append(Self.note("Found \(total) unmapped exits."))
        return out
    }

    /// The per-exit clickable table for an area filter.
    private func unmappedByRoom(intro: String, matchesArea: (String?) -> Bool) -> [ScriptEffect] {
        let border = MapperOutput.border([10, 20, 7, 3, 7])
        var out: [ScriptEffect] = [
            Self.note(""),
            Self.note(intro),
            Self.note(border),
            Self.note("| area       | room name            | rm uid  | dir | to uid  |"),
            Self.note(border)
        ]
        var count = 0
        let rooms = graph.rooms.values
            .filter { !$0.uid.hasPrefix("*") && matchesArea($0.area) }
            .sorted { ($0.area ?? "", $0.uid) < ($1.area ?? "", $1.uid) }
        for room in rooms {
            for exit in unmappedExits(of: room) {
                count += 1
                let rowText = MapperOutput.row([
                    MapperOutput.field(room.area ?? "<No area>", 10),
                    MapperOutput.field(room.name, 20, leftAlign: true),
                    MapperOutput.field(room.uid, 7),
                    MapperOutput.field(exit.dir, 3, leftAlign: true),
                    MapperOutput.field(exit.to, 7)
                ])
                out.append(MapperOutput.gotoRow(
                    rowText,
                    uid: room.uid,
                    hint: "Click to attempt to walk here"
                ))
            }
        }
        out.append(Self.note(border))
        out.append(Self.note("Found \(count) unmapped exits."))
        return out
    }
}
