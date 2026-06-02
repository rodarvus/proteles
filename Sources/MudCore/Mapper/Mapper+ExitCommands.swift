import Foundation

/// The `mapper` portal / custom-exit / findpath / purge command surface,
/// split from Mapper+Commands.swift to keep each file within the length
/// budget. Mirrors `aard_GMCP_mapper`'s command names + DB format for
/// compatibility (verified vs the live Aardwolf.db); implementation is our own.
extension Mapper {
    /// Portals / custom-exit / findpath / purge subcommands, split from
    /// ``handleSecondaryCommand`` to keep each within the complexity budget.
    func handleMapManagementCommand(_ sub: String, _ arg: String) -> [ScriptEffect] {
        switch sub {
        case "portals": listPortals(arg)
        case "portal": addPortalCommand(arg)
        case "fullportal": fullPortalCommand(arg)
        case "cexits": listCustomExits(arg)
        case "cexit": customExitCommand(arg)
        case "fullcexit": fullCustomExitCommand(arg)
        case "cexit_wait": cexitWaitCommand(arg)
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
        default: handlePortalEditCommand(sub, arg)
        }
    }

    /// Portal-edit + exit-lock subcommands (change/recall/level/lockexit),
    /// split out for the complexity budget.
    private func handlePortalEditCommand(_ sub: String, _ arg: String) -> [ScriptEffect] {
        switch sub {
        case "change": changePortalCommand(arg)
        case "portalrecall": portalRecallCommand(arg)
        case "portallevel": portalLevelCommand(arg)
        case "bounceportal": bouncePortalCommand(arg)
        case "bouncerecall": bounceRecallCommand(arg)
        case "lockexit": lockExitCommand(arg)
        default: handleRoomFlagCommand(sub, arg)
        }
    }

    /// Room-flag + maintenance subcommands (reset/backup/noportal/norecall/
    /// ignore mismatch), split out for the complexity budget.
    private func handleRoomFlagCommand(_ sub: String, _ arg: String) -> [ScriptEffect] {
        switch sub {
        case "reset", "resetaard": resetCommand()
        case "backup": backupCommand()
        case "noportal": noportalCommand(arg)
        case "norecall": norecallCommand(arg)
        case "ignore": ignoreMismatchCommand(arg)
        default: [Self.note("Unknown mapper command '\(sub)'. Try 'mapper help'.")]
        }
    }

    /// `mapper reset` (resetaard) — forget the current room and re-request it.
    private func resetCommand() -> [ScriptEffect] {
        clearCurrentRoom()
        return [.sendGMCP("request room"), Self.note("Mapper position reset — re-syncing room.")]
    }

    /// `mapper backup` — copy the map database to a timestamped file beside it.
    private func backupCommand() -> [ScriptEffect] {
        let stamp = Self.backupTimestamp.string(from: Date())
        let dest = store.url.deletingPathExtension().appendingPathExtension("\(stamp).bak.db")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: store.url, to: dest)
            return [Self.note("Map backed up to \(dest.lastPathComponent).")]
        } catch {
            return [Self.note("Backup failed.")]
        }
    }

    private static let backupTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// `mapper lockexit <dir> <level>` — set the level lock on the current
    /// room's exit. (The reference uses a listbox; we take the dir explicitly.)
    private func lockExitCommand(_ arg: String) -> [ScriptEffect] {
        guard let uid = currentRoomUID else { return [Self.note("Your current location is unknown.")] }
        let tokens = arg.split(separator: " ").map(String.init)
        guard tokens.count >= 2, let level = Int(tokens[1]) else {
            return [Self.note("Usage: mapper lockexit <direction> <level>")]
        }
        let changed = (try? store.setExitLevel(from: uid, dir: tokens[0], level: level)) ?? false
        if changed { reloadGraphAndPublish() }
        return [Self.note(changed
                ? "Exit '\(tokens[0])' from room \(uid) locked to level \(max(0, level))."
                : "No '\(tokens[0])' exit from here.")]
    }

    // MARK: - Custom exits (cexits)

    /// The current room's custom (non-cardinal) exits, read from the in-memory
    /// graph — the data source for the Rich Exits feature's clickable custom
    /// tokens. Cardinal exits come from GMCP `room.info`, so they're excluded
    /// here. Sorted by command for a stable display order. Empty when the
    /// current room is unknown or has no custom exits.
    public func currentRoomCustomExits() -> [RichExits.CustomExit] {
        guard let uid = currentRoomUID, let room = graph.rooms[uid] else { return [] }
        return room.exits.values
            .filter { !RichExits.isCardinalDirection($0.dir) }
            .map { RichExits.CustomExit(command: $0.dir, destination: $0.to) }
            .sorted { $0.command < $1.command }
    }

    /// `mapper cexit <command>` (reference `custom_exit`): run the command and
    /// record the room you land in as the destination of a custom exit from the
    /// current room. The confirmation/failure lands after the cexit delay
    /// (``finalizeCexit``).
    private func customExitCommand(_ arg: String) -> [ScriptEffect] {
        let dir = arg.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return [Self.note("Usage: mapper cexit <direction command>")] }
        guard let from = currentRoomUID else { return [Self.note("Your current location is unknown.")] }
        guard from != "-1" else {
            return [Self.note("CEXIT FAILED: You cannot link custom exits from unmappable rooms.")]
        }
        let delay = tempCexitDelay ?? Mapper.cexitDelaySeconds
        tempCexitDelay = nil
        let generation = beginPendingCexit(from: from, dir: dir)
        // Run-and-sample: send the command, then check the destination after
        // the cexit delay (the reference's wait.time + current_room sample).
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            await self?.finalizeCexit(generation: generation)
        }
        return [
            // Re-enter the command pipeline (MUSHclient's `Execute`/
            // ExecuteWithWaits) so a stacked cexit like `open south;s` splits
            // into `open south` then `s` instead of being sent raw.
            .execute(dir),
            Self.note("CEXIT: WAIT FOR CONFIRMATION BEFORE MOVING."),
            Self.note("This should take about \(delay) seconds.")
        ]
    }

    /// `mapper fullcexit {command} <from> <to> [level]` (reference
    /// `custom_fullexit`): add a custom exit with explicit endpoints. Both rooms
    /// must be known; the level lock is taken as an arg (the reference dialog).
    private func fullCustomExitCommand(_ arg: String) -> [ScriptEffect] {
        let groups = Self.braceGroups(arg)
        let trailing = arg.components(separatedBy: "}").last ?? ""
        let tokens = trailing.split(separator: " ").map(String.init)
        guard let dir = groups.first, !dir.isEmpty else { return [Self.note("Nothing to do!")] }
        guard let from = tokens.first else { return [Self.note("CEXIT FAILED: No start room provided.")] }
        guard graph.rooms[from] != nil else {
            return [Self.note("CEXIT FAILED: Room \(from) is unknown.")]
        }
        guard tokens.count >= 2 else { return [Self.note("CEXIT FAILED: No destination room provided.")] }
        let to = tokens[1]
        guard graph.rooms[to] != nil else {
            return [Self.note("CEXIT FAILED: Room \(to) is unknown.")]
        }
        guard to != from else {
            return [Self.note("CEXIT FAILED: Custom Exit \(dir) leads back here!")]
        }
        let level = tokens.count > 2 ? max(0, Int(tokens[2]) ?? 0) : 0
        let quiet = tokens.last == "quiet"
        do {
            try store.addCustomExit(dir: dir, from: from, to: to, level: level)
            reloadGraphAndPublish()
            if quiet { return [] }
            return [Self.note("Custom Exit CONFIRMED: \(from) (\(dir)) -> \(to) [lock level \(level)]")]
        } catch {
            return [Self.note("Couldn't store that custom exit.")]
        }
    }

    // MARK: - portal/findpath argument resolution

    /// Resolve a findpath/portal argument: an all-digit room id, or a unique
    /// room-name match.
    private func resolveUID(_ arg: String) -> String? {
        if looksLikeRoomID(arg) { return arg }
        if case .uid(let uid) = resolveRoom(arg) { return uid }
        return nil
    }

    // MARK: - Portals

    /// `mapper portals [filter]` — list portals + recalls (filter by dest area).
    /// `mapper portal <use-command> [destination] [level]` (reference
    /// `map_portal`): store a portal from anywhere to the destination room
    /// (default: the current room). Destination must be a *known* room. The
    /// reference pops a dialog for the level when omitted; we take it as an
    /// optional argument (default 0 = no lock).
    private func addPortalCommand(_ arg: String) -> [ScriptEffect] {
        let tokens = arg.split(separator: " ").map(String.init)
        guard let dir = tokens.first else {
            return [Self.note("Usage: mapper portal <use-command> [destination-room] [level]")]
        }
        let destination = tokens.count > 1 ? tokens[1] : currentRoomUID
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

    /// The shared `create_portal` body: validate the destination, auto-detect a
    /// recall portal (home/hom/recall), store it, and emit the reference's
    /// messages verbatim.
    private func storePortal(dir rawDir: String, touid: String?, level: Int) -> [ScriptEffect] {
        let dir = rawDir.trimmingCharacters(in: .whitespaces)
        guard let destination = touid else {
            return [Self
                .note(
                    "PORTAL FAILED: No room received from the mud yet. Try using the 'LOOK' command first."
                )]
        }
        guard graph.rooms[destination] != nil else {
            return [Self.note("PORTAL [\(dir)] FAILED: Room \(destination) is unknown.")]
        }
        let recall = ["home", "hom", "recall"].contains(dir.lowercased())
        var out: [ScriptEffect] = []
        if recall {
            out.append(Self.note(""))
            out.append(MapperOutput.colourLine(
                "PORTAL AUTO-DETECT: '\(dir)' was automatically recognized as a recall portal.",
                colour: MapperOutput.autoDetectColour
            ))
            out.append(MapperOutput.colourLine(
                "If this is incorrect, you can change it using 'mapper portalrecall <index>' "
                    + "(find the index with 'mapper portals').",
                colour: MapperOutput.autoDetectColour
            ))
            out.append(Self.note(""))
        }
        do {
            try store.addPortal(dir: dir, touid: destination, level: level, recall: recall)
            reloadGraphAndPublish()
            out.append(Self.note("Storing '\(dir)' as a portal to room \(destination)."))
            out.append(Self.note(""))
            out.append(Self.note("Portal given minimum level lock of \(level)."))
            out.append(Self.note(""))
            return out
        } catch {
            return [Self.note("Couldn't store that portal.")]
        }
    }

    // MARK: - delete / purge

    private func deleteCommand(_ arg: String) -> [ScriptEffect] {
        let tokens = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch tokens.first?.lowercased() {
        case "portal":
            return deletePortalEdit(tokens.count > 1 ? tokens[1] : "")
        case "note":
            return deleteNoteCommand()
        case "cexits":
            return deleteCustomExitsHere()
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
        let normalized = arg.lowercased().split(separator: " ").joined(separator: " ")
        switch normalized {
        case "portals":
            pendingConfirm = "purge portals"
            return [Self.note(
                "Are you sure you want to purge all portal exits? "
                    + "To confirm type 'mapper purge portals confirm'."
            )]
        case "portals confirm":
            guard pendingConfirm == "purge portals" else { return [confirmAborted()] }
            pendingConfirm = nil
            try? store.purgePortals()
            // map_portal_purge also clears the bounce designations.
            bouncePortalDir = nil
            bounceRecallDir = nil
            reloadGraphAndPublish()
            return [Self.note("Purged all mapper portals.")]
        case "cexits":
            pendingConfirm = "purge cexits"
            return [Self.note(
                "Are you sure you want to purge all custom mapper exits? "
                    + "To confirm type 'mapper purge cexits confirm'."
            )]
        case "cexits confirm":
            guard pendingConfirm == "purge cexits" else { return [confirmAborted()] }
            pendingConfirm = nil
            try? store.purgeCustomExits(area: nil)
            reloadGraphAndPublish()
            return [Self.note("Purged all custom exits.")]
        case "cexits area":
            pendingConfirm = "purge cexits area"
            return [Self.note(
                "Are you sure you want to purge all custom mapper exits in this area? "
                    + "To confirm type 'mapper purge cexits area confirm'."
            )]
        case "cexits area confirm":
            guard pendingConfirm == "purge cexits area" else { return [confirmAborted()] }
            pendingConfirm = nil
            let area = currentRoomUID.flatMap { graph.rooms[$0]?.area }
            try? store.purgeCustomExits(area: area)
            reloadGraphAndPublish()
            return [Self.note("Purged all area custom exits.")]
        default:
            return [Self.note("Usage: mapper purge portals | purge cexits [area]")]
        }
    }

    /// The reference's `confirm_catch` failure note for a `… confirm` that
    /// doesn't match the armed token.
    private func confirmAborted() -> ScriptEffect {
        Self.note("Failed to confirm '\(pendingConfirm ?? "")'. Aborting.")
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
    func reloadGraphAndPublish() {
        graph = (try? store.loadGraph()) ?? graph
        publishLayout()
    }

    /// Extract `{…}` groups from a command argument (fullportal/fullcexit).
    static func braceGroups(_ string: String) -> [String] {
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
}
