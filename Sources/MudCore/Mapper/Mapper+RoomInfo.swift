import Foundation

/// Phase 5 of the mapper-fidelity work: room info, notes, and flags — the
/// `thisroom` block, `notes`/`bookmarks` search, `addnote`/`delete note`, and
/// the `noportal`/`norecall`/`ignore mismatch` flags — rendered byte-faithfully
/// to the reference `aard_GMCP_mapper.xml` (`show_this_room`/`map_notes`/
/// `room_edit_note`/`room_delete_note`/`manual_noportal`/`manual_norecall`/
/// `ignore_mismatch`).
extension Mapper {
    // MARK: - thisroom

    /// `mapper thisroom` (reference `show_this_room`): the bordered block of room
    /// details. The reference dumps Exits/Exit-locks via `tprint`, whose Lua
    /// `pairs()` order is itself non-deterministic, so we render those sorted
    /// (the only sane byte-stable choice) in the same `"key"=value` shape.
    func thisRoom() -> [ScriptEffect] {
        guard let uid = currentRoomUID, let room = graph.rooms[uid] else {
            return [Self.note(
                "THISROOM ERROR: You need to type 'LOOK' first to initialize the mapper "
                    + "before trying to get room information."
            )]
        }
        let roomUID = uid.hasPrefix("nomap") ? "\(uid) (this room isn't mappable)" : uid
        var flags = ""
        if room.noportal { flags += " noportal" }
        if room.norecall { flags += " norecall" }

        var out: [ScriptEffect] = [
            Self.note("Details about this room:"),
            Self.note("+---------------------------+"),
            Self.note("Name: \(room.name)"),
            Self.note("ID: \(roomUID)"),
            Self.note("Area: \(room.area ?? "")"),
            Self.note("Terrain: \(room.terrain ?? "")"),
            Self.note("Info: \(room.info ?? "")"),
            Self.note("Notes: \(room.notes ?? "")"),
            Self.note("Flags:\(flags)"),
            Self.note("Exits: ")
        ]
        for (dir, exit) in room.exits.sorted(by: { $0.key < $1.key }) {
            out.append(Self.note("\"\(dir)\"=\"\(exit.to)\""))
        }
        out.append(Self.note("Exit locks: "))
        let locks = room.exits.values.filter { $0.level > 0 }.sorted { $0.dir < $1.dir }
        if locks.isEmpty {
            out.append(Self.note("none"))
        } else {
            for lock in locks {
                out.append(Self.note("\"\(lock.dir)\"=\"\(lock.level)\""))
            }
        }
        out.append(Self.note("Ignore exits mismatch: \(room.ignoreExitsMismatch)"))
        out.append(Self.note("+---------------------------+"))
        out.append(Self.note(""))
        return out
    }

    // MARK: - notes search + edit

    /// `mapper notes [room|thisroom|here|<area>]` (reference `map_notes`): a
    /// quick-find search of bookmarked rooms — clickable rows whose reason is the
    /// note text, prefixed by the reference "Searching …" intro.
    func listNotes(_ arg: String) -> [ScriptEffect] {
        let scope = arg.trimmingCharacters(in: .whitespaces)
        var out: [ScriptEffect] = []
        let predicate: (Room) -> Bool
        switch scope.lowercased() {
        case "room", "thisroom":
            guard let here = currentRoomUID else {
                return [Self.note("I don't know where you are right now - try: LOOK")]
            }
            out.append(Self.note("Searching the current room"))
            predicate = { $0.uid == here }
        case "here":
            out.append(Self.note("Searching the current area"))
            let area = currentRoomUID.flatMap { graph.rooms[$0]?.area }
            predicate = { $0.area == area }
        case "":
            out.append(Self.note("Searching all areas"))
            predicate = { _ in true }
        default:
            out.append(Self.note("Searching areas that partially match '\(scope)'"))
            let needle = scope.lowercased()
            predicate = { ($0.area ?? "").lowercased().contains(needle) }
        }
        let dests = graph.rooms.values
            .filter { !($0.notes ?? "").isEmpty && predicate($0) }
            .sorted { $0.uid < $1.uid }
            .map { FindDest(uid: $0.uid, reason: $0.notes) }
        out.append(contentsOf: runQuickFind(dests, name: "[NOTE]"))
        return out
    }

    /// `mapper note [text]` / `mapper addnote [text]` (reference `room_edit_note`):
    /// add or change the current room's note. The reference pops a dialog when
    /// no text is given; we require it inline.
    func addNoteCommand(_ text: String) -> [ScriptEffect] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uid = currentRoomUID, graph.rooms[uid] != nil else {
            return [Self.note("No room received from the mud yet. Try using the 'LOOK' command first.")]
        }
        guard !trimmed.isEmpty else { return [Self.note("Usage: mapper addnote <note>")] }
        let hadNote = !(graph.rooms[uid]?.notes ?? "").isEmpty
        _ = setNote(trimmed, uid: uid)
        if hadNote {
            return [Self.note("Note for room \(uid) changed to: \(trimmed)")]
        }
        return [Self.note("Note added to room \(uid) : \(trimmed)")]
    }

    /// `mapper delete note` (reference `room_delete_note`).
    func deleteNoteCommand() -> [ScriptEffect] {
        guard let uid = currentRoomUID, let room = graph.rooms[uid] else {
            return [Self.note("No room received from the mud yet. Try using the 'LOOK' command first.")]
        }
        let prev = room.notes ?? ""
        guard !prev.isEmpty else { return [Self.note("No note found here to delete.")] }
        _ = setNote("", uid: uid)
        return [Self.note("Note for room \(uid) deleted. Was previously: \(prev)")]
    }

    // MARK: - flags (noportal / norecall / ignore mismatch)

    /// Labels for a boolean room-flag command's messages.
    private struct FlagText {
        let name: String // "No-portal"
        let noun: String // "portal"
        let tag: String // "NOPORTAL"
    }

    /// `mapper noportal <id> <true|false>` (reference `manual_noportal`).
    func noportalCommand(_ arg: String) -> [ScriptEffect] {
        guard let (id, value) = Self.parseFlagArg(arg) else {
            return [Self.note("Usage: mapper noportal <id> <true|false>")]
        }
        return setRoomFlag(
            id: id,
            value: value,
            keyPath: \.noportal,
            text: FlagText(name: "No-portal", noun: "portal", tag: "NOPORTAL")
        )
    }

    /// `mapper norecall <id> <true|false>` (reference `manual_norecall`).
    func norecallCommand(_ arg: String) -> [ScriptEffect] {
        guard let (id, value) = Self.parseFlagArg(arg) else {
            return [Self.note("Usage: mapper norecall <id> <true|false>")]
        }
        return setRoomFlag(
            id: id,
            value: value,
            keyPath: \.norecall,
            text: FlagText(name: "No-recall", noun: "recall", tag: "NORECALL")
        )
    }

    /// `mapper ignore mismatch [<id>] <true|false>` (reference `ignore_mismatch`):
    /// the id defaults to the current room.
    func ignoreMismatchCommand(_ arg: String) -> [ScriptEffect] {
        let tokens = arg.split(separator: " ").map(String.init)
        guard tokens.first?.lowercased() == "mismatch",
              let last = tokens.last, let value = Self.boolToken(last), tokens.count >= 2
        else { return [Self.note("Usage: mapper ignore mismatch [<id>] <true|false>")] }
        let idTokens = tokens.dropFirst().dropLast()
        let id = idTokens.isEmpty ? currentRoomUID : idTokens.joined(separator: " ")
        guard let roomID = id else {
            return [Self.note("IGNORE EXITS MISMATCH ERROR: I do not know your room! "
                    + "Try typing 'LOOK' first, or pick a room.")]
        }
        guard var room = graph.rooms[roomID] else {
            return [Self.note("IGNORE EXITS MISMATCH ERROR: Room \(roomID) is not in the database.")]
        }
        room.ignoreExitsMismatch = value
        graph[roomID] = room
        try? store.upsert(room)
        publishLayout()
        return [Self.note("Ignore exits mismatch flag \(value ? "set on" : "removed from") room \(roomID).")]
    }

    /// Set a boolean room flag by id (noportal/norecall), with the reference's
    /// set/removed/already/error messages.
    private func setRoomFlag(
        id: String, value: Bool, keyPath: WritableKeyPath<Room, Bool>, text: FlagText
    ) -> [ScriptEffect] {
        guard var room = graph.rooms[id] else {
            return [Self.note("GMCP MAPPER \(text.tag) ERROR: Room \(id) is not in the database.")]
        }
        guard room[keyPath: keyPath] != value else {
            return [Self.note("GMCP Mapper: Room \(id) already has that \(text.noun) status.")]
        }
        room[keyPath: keyPath] = value
        graph[id] = room
        try? store.upsert(room)
        publishLayout()
        return [Self.note("GMCP Mapper: \(text.name) flag \(value ? "set on" : "removed from") room \(id).")]
    }

    /// Parse `<id> <true|false>` for the noportal/norecall commands.
    private static func parseFlagArg(_ arg: String) -> (id: String, value: Bool)? {
        let tokens = arg.split(separator: " ").map(String.init)
        guard tokens.count >= 2, let last = tokens.last, let value = boolToken(last) else { return nil }
        return (tokens.dropLast().joined(separator: " "), value)
    }

    private static func boolToken(_ token: String) -> Bool? {
        switch token.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }
}
