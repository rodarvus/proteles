import Foundation

/// Phase 3 (part 2): the portal-edit + bounce commands — `delete`/`change`
/// portal, `portalrecall`, `portallevel`, `bounceportal`, `bouncerecall` —
/// rendered byte-faithfully to the reference `aard_GMCP_mapper.xml`
/// (`map_portal_edit`/`map_portal_recall`/`map_portal_level`/`map_bounceportal`/
/// `map_bouncerecall`).
///
/// All of these address portals by their **index** in the unfiltered portal
/// list (the reference `PORTALS_QUERY()` order: area, then destination uid).
/// `delete`/`change` also accept literal keywords; the index-only commands
/// (recall/level/bounce) take a bare number.
extension Mapper {
    /// The full ordered portal list (reference `PORTALS_QUERY()` order).
    private func orderedPortals() -> [MapperStore.PortalEntry] {
        (try? store.portals(areaFilter: nil)) ?? []
    }

    /// A `#N` index token → its 1-based Int, else `nil`.
    private static func portalIndexToken(_ token: String) -> Int? {
        guard token.hasPrefix("#") else { return nil }
        return Int(token.dropFirst())
    }

    // MARK: - delete / change (keywords or #index)

    /// `mapper delete portal <#N|keywords>` (reference `map_portal_edit`,
    /// name = DELETE).
    func deletePortalEdit(_ raw: String) -> [ScriptEffect] {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return [Self.note("Usage: mapper delete portal <#N or keywords>")] }
        let resolved = resolvePortalTarget(token, op: "DELETE")
        switch resolved {
        case .failure(let note): return [note]
        case .success(let keywords, let indexLabel):
            guard orderedPortals().contains(where: { $0.dir == keywords }) else {
                return [Self.note("DELETE FAILED: Did not find a mapper portal with keywords '\(keywords)'.")]
            }
            _ = try? store.deletePortal(dir: keywords)
            reloadGraphAndPublish()
            return [Self.note("Deleted mapper portal\(indexLabel) with keywords '\(keywords)'.")]
        }
    }

    /// `mapper change portal {old|#N} {new}` (reference `map_portal_edit`,
    /// name = CHANGE).
    func changePortalCommand(_ arg: String) -> [ScriptEffect] {
        let rest = arg.split(separator: " ", maxSplits: 1).map(String.init)
        guard rest.first?.lowercased() == "portal" else {
            return [Self.note("Usage: mapper change portal {old} {new}")]
        }
        let groups = Self.braceGroups(rest.count > 1 ? rest[1] : "")
        guard groups.count >= 2 else {
            return [Self.note("Usage: mapper change portal {old or #N} {new}")]
        }
        let newCommand = groups[1]
        switch resolvePortalTarget(groups[0], op: "CHANGE") {
        case .failure(let note): return [note]
        case .success(let keywords, let indexLabel):
            guard orderedPortals().contains(where: { $0.dir == keywords }) else {
                return [Self.note("CHANGE FAILED: Did not find a mapper portal with keywords '\(keywords)'.")]
            }
            _ = try? store.changePortal(from: keywords, to: newCommand)
            reloadGraphAndPublish()
            return [Self.note("Changed mapper portal\(indexLabel) to command '\(newCommand)'.")]
        }
    }

    private enum PortalTarget {
        case success(keywords: String, indexLabel: String)
        case failure(ScriptEffect)
    }

    /// Resolve a delete/change target that's either `#N` (an index) or literal
    /// keywords. `op` is the alias name (DELETE/CHANGE) used in the failure note.
    private func resolvePortalTarget(_ token: String, op: String) -> PortalTarget {
        guard let idx = Self.portalIndexToken(token) else {
            return .success(keywords: token, indexLabel: "")
        }
        let portals = orderedPortals()
        guard idx >= 1, idx <= portals.count else {
            return .failure(Self.note(
                "\(op) FAILED: Did not find portal #\(idx) in the list of portals. "
                    + "Try 'mapper portals' to see the list."
            ))
        }
        return .success(keywords: portals[idx - 1].dir, indexLabel: " index #\(idx)")
    }

    // MARK: - portalrecall / portallevel (index)

    /// `mapper portalrecall <#>` — toggle a portal's recall flag by index.
    func portalRecallCommand(_ arg: String) -> [ScriptEffect] {
        guard let pnum = Int(arg.trimmingCharacters(in: .whitespaces)) else {
            return [Self.note(
                "PORTALRECALL FAILED: The required parameter for mapper portalrecall is <portal_index>. "
                    + "Current portal indexes can be found in the 'mapper portals' output."
            )]
        }
        let portals = orderedPortals()
        guard pnum >= 1, pnum <= portals.count else {
            return [portalIndexNotFound("PORTALRECALL", pnum)]
        }
        let portal = portals[pnum - 1]
        guard let nowRecall = (try? store.setPortalRecall(dir: portal.dir)).flatMap(\.self) else {
            return [portalIndexNotFound("PORTALRECALL", pnum)]
        }
        reloadGraphAndPublish()
        let verb = nowRecall ? "added to" : "removed from"
        return [Self.note(
            "PORTALRECALL: Recall flag \(verb) portal '\(portal.dir)' to '\(portal.roomName ?? "N/A")'."
        )]
    }

    /// `mapper portallevel <#> <level> [quiet]` — set a portal's level lock.
    func portalLevelCommand(_ arg: String) -> [ScriptEffect] {
        let keys = arg.split(separator: " ").map(String.init)
        guard keys.count >= 2, let pnum = Int(keys[0]), let parsedLevel = Int(keys[1]) else {
            return [Self.note(
                "PORTALLEVEL FAILED: The parameters for mapper portallevel are "
                    + "<portal_index> <min_level> [quiet]. "
                    + "Current portal indexes can be found in the 'mapper portals' output."
            )]
        }
        let level = max(0, parsedLevel)
        let quiet = keys.count > 2 && keys[2] == "quiet"
        let portals = orderedPortals()
        guard pnum >= 1, pnum <= portals.count else {
            return [portalIndexNotFound("PORTALLEVEL", pnum)]
        }
        let portal = portals[pnum - 1]
        _ = try? store.setPortalLevel(dir: portal.dir, level: level)
        reloadGraphAndPublish()
        if quiet { return [] }
        return [Self.note(
            "Portal '\(portal.dir)' to '\(portal.roomName ?? "N/A")' given minimum level lock of \(level)."
        )]
    }

    // MARK: - bounceportal / bouncerecall

    /// `mapper bounceportal [#|clear]` — designate (or show/clear) the portal
    /// used to bounce out of portal-friendly norecall rooms.
    func bouncePortalCommand(_ arg: String) -> [ScriptEffect] {
        let token = arg.trimmingCharacters(in: .whitespaces)
        if token.isEmpty {
            return [Self.note(bouncePortalDir.map { "BOUNCEPORTAL: Currently set to '\($0)'" }
                    ?? "BOUNCEPORTAL: Not currently set.")]
        }
        if token.lowercased() == "clear" {
            bouncePortalDir = nil
            return [Self.note("BOUNCEPORTAL: cleared.")]
        }
        guard let pnum = Int(token) else {
            return [Self.note(
                "BOUNCEPORTAL FAILED: The required parameter for mapper bounceportal is <portal_index>. "
                    + "Current portal indexes can be found in the 'mapper portals' output."
            )]
        }
        let portals = orderedPortals()
        guard pnum >= 1, pnum <= portals.count else {
            return [portalIndexNotFound("BOUNCEPORTAL", pnum)]
        }
        let portal = portals[pnum - 1]
        guard !portal.isRecall else {
            return [Self.note(
                "BOUNCEPORTAL FAILED: Portal #\(pnum) is a recall portal. You must choose a mapper portal "
                    + "that does not use either the recall or home commands for the bounce portal."
            )]
        }
        bouncePortalDir = portal.dir
        return [Self.note(
            "BOUNCEPORTAL: Set portal #\(pnum) (\(portal.dir)) as the bounce portal "
                + "for portal-friendly norecall rooms."
        )]
    }

    /// `mapper bouncerecall [#|clear]` — designate (or show/clear) the recall
    /// portal used to bounce out of recall-friendly noportal rooms.
    func bounceRecallCommand(_ arg: String) -> [ScriptEffect] {
        let token = arg.trimmingCharacters(in: .whitespaces)
        if token.isEmpty {
            return [Self.note(bounceRecallDir.map { "BOUNCERECALL: Currently set to '\($0)'" }
                    ?? "BOUNCERECALL: Not currently set.")]
        }
        if token.lowercased() == "clear" {
            bounceRecallDir = nil
            return [Self.note("BOUNCERECALL: cleared.")]
        }
        guard let pnum = Int(token) else {
            return [Self.note(
                "BOUNCERECALL FAILED: The required parameter for mapper bouncerecall is "
                    + "<recall_portal_index>. Current portal indexes can be found in the "
                    + "'mapper portals' output."
            )]
        }
        let portals = orderedPortals()
        guard pnum >= 1, pnum <= portals.count else {
            return [portalIndexNotFound("BOUNCERECALL", pnum)]
        }
        let portal = portals[pnum - 1]
        guard portal.isRecall else {
            return [Self.note(
                "BOUNCERECALL FAILED: Portal #\(pnum) is not a recall portal. You must choose a mapper "
                    + "portal that uses either the recall or home commands for the bounce recall."
            )]
        }
        bounceRecallDir = portal.dir
        return [Self.note(
            "BOUNCERECALL: Set recall portal #\(pnum) (\(portal.dir)) as the bounce recall "
                + "for recall-friendly noportal rooms."
        )]
    }

    /// The shared "Did not find index N" failure note.
    private func portalIndexNotFound(_ op: String, _ pnum: Int) -> ScriptEffect {
        Self.note("\(op) FAILED: Did not find index \(pnum) in the list of portals. "
            + "Try 'mapper portals' to see the list.")
    }
}
