import Foundation

/// The `mapper` portal / custom-exit / findpath / purge command surface,
/// split from Mapper+Commands.swift to keep each file within the length
/// budget. Faithful to aard_GMCP_mapper (verified vs the live Aardwolf.db).
extension Mapper {
    /// Portals / custom-exit / findpath / purge subcommands, split from
    /// ``handleSecondaryCommand`` to keep each within the complexity budget.
    func handleMapManagementCommand(_ sub: String, _ arg: String) -> [ScriptEffect] {
        switch sub {
        case "findpath": findPath(arg)
        case "portals": listPortals(arg)
        case "portal": addPortalCommand(arg)
        case "fullportal": fullPortalCommand(arg)
        case "cexits": listCustomExits(arg)
        case "cexit": customExitCommand(arg)
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
        case "noportal": setCurrentRoomFlag(\.noportal, name: "noportal", arg: arg)
        case "norecall": setCurrentRoomFlag(\.norecall, name: "norecall", arg: arg)
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

    /// `mapper ignore mismatch [on|off]` — set the current room's
    /// ignore-exits-mismatch flag.
    private func ignoreMismatchCommand(_ arg: String) -> [ScriptEffect] {
        let rest = arg.split(separator: " ", maxSplits: 1).map(String.init)
        guard rest.first?.lowercased() == "mismatch" else {
            return [Self.note("Usage: mapper ignore mismatch on|off")]
        }
        return setCurrentRoomFlag(
            \.ignoreExitsMismatch,
            name: "ignore mismatch",
            arg: rest.count > 1 ? rest[1] : ""
        )
    }

    /// Set (or show) a boolean flag on the current room (noportal/norecall/
    /// ignore-mismatch); these feed the Pathfinder + redraw the map.
    private func setCurrentRoomFlag(
        _ keyPath: WritableKeyPath<Room, Bool>,
        name: String,
        arg: String
    ) -> [ScriptEffect] {
        guard let uid = currentRoomUID, var room = graph.rooms[uid] else {
            return [Self.note("Your current location is unknown.")]
        }
        let on: Bool
        switch arg.lowercased() {
        case "on", "true", "yes": on = true
        case "off", "false", "no": on = false
        case "":
            return [Self.note("\(name) for room \(uid) is \(room[keyPath: keyPath] ? "on" : "off").")]
        default:
            return [Self.note("Usage: mapper \(name) on|off")]
        }
        room[keyPath: keyPath] = on
        graph[uid] = room
        try? store.upsert(room)
        publishLayout()
        return [Self.note("\(name) \(on ? "set on" : "cleared for") room \(uid).")]
    }

    /// Resolve a portal reference: `#N` (1-based index into the portal list) or
    /// the portal's use-command directly.
    private func resolvePortalDir(_ token: String) -> String? {
        if token.hasPrefix("#"), let index = Int(token.dropFirst()), index >= 1 {
            let portals = (try? store.portals()) ?? []
            return index <= portals.count ? portals[index - 1].dir : nil
        }
        return token.isEmpty ? nil : token
    }

    /// `mapper change portal {old} {new}` — rename a portal's use-command.
    private func changePortalCommand(_ arg: String) -> [ScriptEffect] {
        let rest = arg.split(separator: " ", maxSplits: 1).map(String.init)
        guard rest.first?.lowercased() == "portal" else {
            return [Self.note("Usage: mapper change portal {old} {new}")]
        }
        let groups = Self.braceGroups(rest.count > 1 ? rest[1] : "")
        guard groups.count >= 2, let old = resolvePortalDir(groups[0]) else {
            return [Self.note("Usage: mapper change portal {old or #N} {new}")]
        }
        let changed = (try? store.changePortal(from: old, to: groups[1])) ?? false
        if changed { reloadGraphAndPublish() }
        return [Self.note(changed ? "Renamed portal to '\(groups[1])'." : "No portal '\(old)'.")]
    }

    /// `mapper portalrecall <#N|dir>` — toggle a portal's recall flag.
    private func portalRecallCommand(_ arg: String) -> [ScriptEffect] {
        guard let dir = resolvePortalDir(arg.trimmingCharacters(in: .whitespaces)) else {
            return [Self.note("Usage: mapper portalrecall <#N or use-command>")]
        }
        guard let recall = (try? store.setPortalRecall(dir: dir)).flatMap(\.self) else {
            return [Self.note("No portal '\(dir)'.")]
        }
        reloadGraphAndPublish()
        return [Self.note("Recall flag \(recall ? "added to" : "removed from") portal '\(dir)'.")]
    }

    /// `mapper portallevel <#N|dir> <level>` — set a portal's level lock.
    private func portalLevelCommand(_ arg: String) -> [ScriptEffect] {
        let tokens = arg.split(separator: " ").map(String.init)
        guard tokens.count >= 2, let dir = resolvePortalDir(tokens[0]), let level = Int(tokens[1]) else {
            return [Self.note("Usage: mapper portallevel <#N or use-command> <level>")]
        }
        let changed = (try? store.setPortalLevel(dir: dir, level: level)) ?? false
        if changed { reloadGraphAndPublish() }
        return [Self.note(changed ? "Portal '\(dir)' level set to \(max(0, level))." : "No portal '\(dir)'.")]
    }

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

    /// `mapper cexit <dir>` — record a custom exit interactively: send the
    /// direction command and record the room you land in as the destination
    /// (resolved on the next room.info, mirroring the reference's run-and-sample).
    private func customExitCommand(_ arg: String) -> [ScriptEffect] {
        let dir = arg.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return [Self.note("Usage: mapper cexit <direction command>")] }
        guard let from = currentRoomUID else { return [Self.note("Your current location is unknown.")] }
        let generation = beginPendingCexit(from: from, dir: dir)
        // Run-and-sample: send the command, then check the destination after
        // the cexit delay (the reference's wait.time + current_room sample).
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Mapper.cexitDelaySeconds) * 1_000_000_000)
            await self?.finalizeCexit(generation: generation)
        }
        return [
            // Re-enter the command pipeline (MUSHclient's `Execute`/
            // ExecuteWithWaits) so a stacked cexit like `open south;s` splits
            // into `open south` then `s` instead of being sent raw.
            .execute(dir),
            Self.note(
                "CEXIT: wait for confirmation before moving. "
                    + "This should take about \(Mapper.cexitDelaySeconds) seconds."
            )
        ]
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
    func reloadGraphAndPublish() {
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
}
