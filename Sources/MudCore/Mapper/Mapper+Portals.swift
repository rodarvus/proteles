import Foundation

/// Phase 3 of the mapper-fidelity work: the `mapper portals` table, rendered
/// byte-faithfully to the reference `aard_GMCP_mapper.xml` `map_portal_list`.
///
/// The reference table (at the default 80-column width, i.e. `name_expand` /
/// `cmd_expand` = 0) is a bordered `# | area | room name | vnum | portal
/// commands | lvl` grid. A leading marker column carries `*` for the designated
/// bounce portal/recall. Rows are CLICKABLE (→ `mapper goto <vnum>`) when the
/// portal's level lock is within reach (`level + tier*10`); recall portals
/// (`fromuid == "**"`) render red. The `#` is the portal's index in the *full*
/// (unfiltered) list, so it's stable when the list is area-filtered.
extension Mapper {
    /// Default-width column sizes (marker+#, area, room name, vnum, commands,
    /// lvl) — we render at a fixed width, so the reference's terminal-width
    /// expansion is always zero.
    private static let portalColumns = [3, 10, 20, 5, 20, 3]

    /// `mapper portals [here|<area>]` — the bordered portal/recall table.
    func listPortals(_ arg: String) -> [ScriptEffect] {
        let pattern = arg.trimmingCharacters(in: .whitespaces)
        let title: String
        let filter: String?
        if pattern.lowercased() == "here" {
            title = "Mapper portals in the current area:"
            filter = currentRoomUID.flatMap { graph.rooms[$0]?.area }
        } else if pattern.isEmpty {
            title = "Mapper portals:"
            filter = nil
        } else {
            title = "Mapper portals to areas matching '\(pattern)':"
            filter = pattern
        }

        // The `#` index comes from the full (unfiltered) list, keyed by command.
        let all = (try? store.portals(areaFilter: nil)) ?? []
        var indexByDir: [String: Int] = [:]
        for (i, portal) in all.enumerated() {
            indexByDir[portal.dir] = i + 1
        }
        let portals = filter == nil ? all : ((try? store.portals(areaFilter: filter)) ?? [])

        let border = MapperOutput.border(Self.portalColumns)
        var out: [ScriptEffect] = [
            Self.note(""),
            Self.note(title),
            Self.note(border),
            Self.note(portalHeaderRow),
            Self.note(border)
        ]
        let reach = level + tier * 10
        for portal in portals {
            out.append(portalRow(
                portal,
                number: indexByDir[portal.dir] ?? 0,
                reachable: portal.level <= reach
            ))
        }
        out.append(Self.note(border))
        out.append(Self.note("|* Indicates designated bouncerecall/bounceportal |"))
        out.append(Self.note("+-------------------------------------------------+"))
        out.append(Self.note(""))
        return out
    }

    /// The header row, built through the same column logic as the data rows so
    /// it lines up with the border exactly.
    private var portalHeaderRow: String {
        portalRowText(marker: " ", ["#", "area", "room name", "vnum", "portal commands", "lvl"])
    }

    /// One portal/recall row. Clickable (→ `mapper goto <vnum>`) when reachable;
    /// recall portals render red. `*` marks a designated bounce portal/recall
    /// (no bounce designations yet, so always a space — the footer still shows
    /// the legend, matching the reference).
    private func portalRow(_ portal: MapperStore.PortalEntry, number: Int, reachable: Bool) -> ScriptEffect {
        let marker = isDesignatedBounce(portal) ? "*" : " "
        let text = portalRowText(marker: marker, [
            String(number),
            portal.area ?? "N/A",
            portal.roomName ?? "N/A",
            portal.touid,
            portal.dir,
            String(portal.level)
        ])
        guard reachable else { return Self.note(text) }
        return MapperOutput.gotoRow(
            text,
            uid: portal.touid,
            hint: "click here to run to \(portal.roomName ?? "N/A")\n[ \(portal.dir) ]",
            foreground: portal.isRecall ? MapperOutput.errorColour : MapperOutput.noteColour
        )
    }

    /// Whether a portal is the currently designated bounce portal/recall.
    /// Bounce designation isn't implemented yet, so this is always `false`.
    private func isDesignatedBounce(_: MapperStore.PortalEntry) -> Bool {
        false
    }

    /// Format one row's text. The leading marker takes the place of the usual
    /// leading cell space (`"|" + marker + %3.3s + " | " + …`), so the marker+#
    /// cell is 5 wide — matching the 3-width border column.
    /// `cells` = [number, area, room name, vnum, portal commands, level].
    private func portalRowText(marker: String, _ cells: [String]) -> String {
        "|" + marker
            + MapperOutput.field(cells[0], 3) + " | "
            + MapperOutput.field(cells[1], 10, leftAlign: true) + " | "
            + MapperOutput.field(cells[2], 20, leftAlign: true) + " | "
            + MapperOutput.field(cells[3], 5) + " | "
            + MapperOutput.field(cells[4], 20, leftAlign: true) + " | "
            + MapperOutput.field(cells[5], 3) + " |"
    }
}
