import Foundation

/// Phase 4 of the mapper-fidelity work: the custom-exit listing, delete, and
/// the cexit-delay command, rendered byte-faithfully to the reference
/// `aard_GMCP_mapper.xml` (`custom_exit_list`/`map_cexits_delete`/
/// `change_cexit_delay`). The `cexit`/`fullcexit` create flows and the
/// `purge cexits` confirm live in Mapper+ExitCommands.
extension Mapper {
    /// `mapper cexits [here|thisroom|<area>]` (reference `custom_exit_list`): a
    /// bordered, clickable table of custom (non-cardinal, non-portal) exits.
    func listCustomExits(_ arg: String) -> [ScriptEffect] {
        let area = arg.trimmingCharacters(in: .whitespaces)
        let intro: String
        let predicate: (MapperStore.CustomExitEntry) -> Bool
        switch area.lowercased() {
        case "":
            intro = "The following rooms have custom exits:"
            predicate = { _ in true }
        case "here":
            guard let here = currentRoomUID.flatMap({ graph.rooms[$0]?.area }) else {
                return [Self.note(
                    "CEXITS HERE ERROR: The mapper doesn't know where you are. Type 'LOOK' and try again."
                )]
            }
            intro = "The following rooms in the current area have custom exits:"
            predicate = { $0.area?.lowercased() == here.lowercased() }
        case "thisroom":
            guard let here = currentRoomUID else {
                return [Self.note(
                    "CEXITS THISROOM ERROR: The mapper doesn't know where you are. Type 'LOOK' and try again."
                )]
            }
            intro = "The following custom exits are in this room:"
            predicate = { $0.fromuid == here }
        default:
            intro = "The following rooms in areas partially matching '\(area)' have custom exits:"
            let needle = area.lowercased()
            predicate = { ($0.area ?? "").lowercased().contains(needle) }
        }

        let exits = ((try? store.customExits(areaFilter: nil)) ?? []).filter(predicate)
        let border = MapperOutput.border([10, 20, 7, 20, 7])
        var out: [ScriptEffect] = [
            Self.note(""),
            Self.note(intro),
            Self.note(border),
            Self.note(cexitRowText(["area", "room name", "rm uid", "dir", "to uid"])),
            Self.note(border)
        ]
        for exit in exits {
            let text = cexitRowText([
                exit.area ?? "<No area>", exit.roomName ?? "N/A", exit.fromuid, exit.dir, exit.touid
            ])
            out.append(MapperOutput.gotoRow(text, uid: exit.fromuid, hint: exit.dir))
        }
        out.append(Self.note(border))
        out.append(Self.note("Found \(exits.count) custom exits."))
        return out
    }

    /// Format one cexits row. `cells` = [area, room name, rm uid, dir, to uid];
    /// matches the reference fmt `| %-10.10s | %s | %7.7s | %s | %7.7s |` (name
    /// and dir are exact-length 20, uid/touid right-aligned 7).
    private func cexitRowText(_ cells: [String]) -> String {
        "| " + MapperOutput.field(cells[0], 10, leftAlign: true)
            + " | " + MapperOutput.field(cells[1], 20, leftAlign: true)
            + " | " + MapperOutput.field(cells[2], 7)
            + " | " + MapperOutput.field(cells[3], 20, leftAlign: true)
            + " | " + MapperOutput.field(cells[4], 7) + " |"
    }

    /// `mapper delete cexits` (reference `map_cexits_delete`): report each custom
    /// exit from the current room, then remove them all.
    func deleteCustomExitsHere() -> [ScriptEffect] {
        guard let here = currentRoomUID, let room = graph.rooms[here] else {
            return [Self.note(
                "EXIT DELETE ERROR: The mapper doesn't know where you are. Type 'LOOK' and try again."
            )]
        }
        var out: [ScriptEffect] = []
        let custom = room.exits.values
            .filter { !RichExits.isCardinalDirection($0.dir) }
            .sorted { $0.dir < $1.dir }
        for exit in custom {
            let destName = graph.rooms[exit.to]?.name ?? "N/A"
            out.append(Self.note("Found custom exit \"\(exit.dir)\" to room \(exit.to) \"\(destName)\""))
        }
        _ = try? store.deleteCustomExits(from: here)
        reloadGraphAndPublish()
        out.append(Self.note("Removed custom exits from the current room."))
        return out
    }

    /// `mapper cexit_wait <seconds>` (reference `change_cexit_delay`): arm a
    /// one-shot override of the next cexit's wait (2–40 seconds).
    func cexitWaitCommand(_ arg: String) -> [ScriptEffect] {
        let value = arg.trimmingCharacters(in: .whitespaces)
        var out: [ScriptEffect] = []
        if let seconds = Int(value), seconds >= 2, seconds <= 40 {
            tempCexitDelay = seconds
        } else {
            out.append(Self.note(
                "CEXIT_DELAY FAILED: Invalid delay given (\(value)). Must be a number from 2 to 40."
            ))
            tempCexitDelay = nil
        }
        let effective = tempCexitDelay ?? Mapper.cexitDelaySeconds
        out.append(Self.note(
            "CEXIT_DELAY: The next mapper custom exit will have \(effective) seconds to complete."
        ))
        return out
    }
}
