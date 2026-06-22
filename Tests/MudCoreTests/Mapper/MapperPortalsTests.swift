import Foundation
@testable import MudCore
import Testing

/// Phase 3 of the mapper-fidelity work: portals & recalls. Table layout,
/// clickability/level-gating, recall colour, the `portal` create messages +
/// recall auto-detect, and the `purge portals confirm` step — all checked
/// against the reference `aard_GMCP_mapper.xml` (`map_portal_list`/`map_portal`/
/// `create_portal`/`map_portal_purge`).
@Suite("Mapper — portals & recalls (Phase 3)")
struct MapperPortalsTests {
    /// A mapper with area `aylor` and a destination room 100, current room 1.
    private func makeMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-portals-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":100,"name":"Aylor Inn","zone":"aylor","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Square","zone":"aylor","exits":{}}"#
        )
        return mapper
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { segs.map(\.text).joined() } else { nil }
        }
    }

    private func firstSegment(_ effect: ScriptEffect) -> NoteSegment? {
        if case .colourNote(let segs) = effect { segs.first } else { nil }
    }

    private let border = "+-----+------------+----------------------+-------+----------------------+-----+"
    private let header = "|   # | area       | room name            |  vnum | portal commands      | lvl |"

    // MARK: - table layout

    @Test("an empty portals table still prints the framed header + legend footer")
    func emptyTable() async throws {
        let mapper = try await makeMapper()
        let out = await notes(mapper.handleCommand("mapper portals"))
        #expect(out.contains("Mapper portals:"))
        #expect(out.contains(border))
        #expect(out.contains(header))
        #expect(out.contains("|* Indicates designated bouncerecall/bounceportal |"))
        #expect(out.contains("+-------------------------------------------------+"))
    }

    @Test("a stored portal renders a clickable row with the reference columns")
    func portalRow() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0")
        let effects = await mapper.handleCommand("mapper portals")
        let out = notes(effects)
        // Header/border are byte-faithful anchors.
        #expect(out.contains(border))
        #expect(out.contains(header))
        // The data row, field-formatted exactly per the reference fmt.
        #expect(out
            .contains("|   1 | aylor      | Aylor Inn            |   100 | nexus                |   0 |"))
        // Level 0 ≤ reach(0) → clickable to the destination, default (green) colour.
        let row = effects.first { firstSegment($0)?.link?.action == .sendCommand("mapper goto 100") }
        #expect(row != nil)
        #expect(try firstSegment(#require(row))?.foreground == MapperOutput.noteColour)
    }

    @Test("a recall portal row renders red")
    func recallRowRed() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {recall} {100} 0")
        let effects = await mapper.handleCommand("mapper portals")
        let row = effects.first { firstSegment($0)?.link?.action == .sendCommand("mapper goto 100") }
        #expect(try firstSegment(#require(row))?.foreground == MapperOutput.errorColour)
    }

    @Test("a portal above the level lock is not clickable")
    func levelGatedRow() async throws {
        let mapper = try await makeMapper()
        // level lock 100 > reach (level 0 + tier 0) → plain, non-clickable note.
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 100")
        let effects = await mapper.handleCommand("mapper portals")
        let row = effects.first { notes([$0]).first?.contains("nexus") == true }
        #expect(try firstSegment(#require(row))?.link == nil)
    }

    // MARK: - portal create messages

    @Test("portal create prints the storing + level-lock messages")
    func createMessages() async throws {
        let mapper = try await makeMapper()
        let out = await notes(mapper.handleCommand("mapper fullportal {nexus} {100} 75"))
        #expect(out.contains("Storing 'nexus' as a portal to room 100."))
        #expect(out.contains("Portal given minimum level lock of 75."))
    }

    @Test("mapper portal takes the WHOLE rest of the line as a multi-word keyword")
    func multiWordKeywordToCurrentRoom() async throws {
        // Regression for the live failure `mapper portal dinv portal use 3786029567`
        // → "PORTAL [dinv] FAILED: Room portal is unknown." The reference alias
        // `^mapper portal (.+)$` passes the entire capture through as the keyword
        // and defaults the destination to the current room — it does NOT split on
        // spaces (the old code mis-read token[1] "portal" as a destination room).
        // makeMapper's current room is 1 (Square, ingested last).
        let mapper = try await makeMapper()
        let cmd = "dinv portal use 3786029567"
        let out = await notes(mapper.handleCommand("mapper portal \(cmd)"))
        // The whole multi-word command is the keyword; destination is the current room.
        #expect(out.contains("Storing '\(cmd)' as a portal to room 1."))
        #expect(!out.contains { $0.contains("FAILED") })
    }

    @Test("mapper portal prompts for the level lock (reference title/default) and stores it")
    func portalLevelPromptViaDialog() async throws {
        let mapper = try await makeMapper()
        let captured = DialogCapture()
        await mapper.setDialogProvider { request in
            captured.store(request)
            return .text("75")
        }
        // No level on the command line → the dialog supplies it (reference
        // `map_portal` → `utils.inputbox`). Current room is 1 (Square).
        let out = await notes(mapper.handleCommand("mapper portal nexus"))
        #expect(out.contains("Storing 'nexus' as a portal to room 1."))
        #expect(out.contains("Portal given minimum level lock of 75."))
        // The prompt mirrors the reference utils.inputbox call exactly.
        if case .input(let msg, let title, let def, let multiline) = captured.value {
            #expect(title == "Portal Level")
            #expect(def == "0")
            #expect(multiline == false)
            #expect(msg.contains("Please enter the level of your portal to 1"))
        } else {
            Issue.record("expected an .input dialog request, got \(String(describing: captured.value))")
        }
    }

    @Test("cancelling the level prompt aborts portal creation")
    func portalLevelPromptCancel() async throws {
        let mapper = try await makeMapper()
        await mapper.setDialogProvider { _ in .text(nil) } // user pressed Cancel
        #expect(await notes(mapper.handleCommand("mapper portal nexus"))
            == ["No level given. Portal creation cancelled."])
        // Nothing was stored.
        let list = await notes(mapper.handleCommand("mapper portals"))
        #expect(!list.contains { $0.contains("nexus") })
    }

    @Test("a recall keyword auto-detects as a recall portal")
    func recallAutoDetect() async throws {
        let mapper = try await makeMapper()
        let effects = await mapper.handleCommand("mapper fullportal {recall} {100} 0")
        let out = notes(effects)
        #expect(out.contains("PORTAL AUTO-DETECT: 'recall' was automatically recognized as a recall portal."))
        // The auto-detect notice is yellow.
        let notice = effects.first { notes([$0]).first?.hasPrefix("PORTAL AUTO-DETECT") == true }
        #expect(try firstSegment(#require(notice))?.foreground == MapperOutput.autoDetectColour)
    }

    @Test("portal to an unknown room fails with the reference message")
    func createUnknownRoom() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper fullportal {nexus} {999} 0"))
            == ["PORTAL [nexus] FAILED: Room 999 is unknown."])
    }

    // MARK: - purge portals confirm

    @Test("purge portals arms a confirm, and confirm clears all portals")
    func purgeConfirm() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0")
        #expect(await notes(mapper.handleCommand("mapper purge portals")) == [
            "Are you sure you want to purge all portal exits? "
                + "To confirm type 'mapper purge portals confirm'."
        ])
        #expect(await notes(mapper.handleCommand("mapper purge portals confirm"))
            == ["Purged all mapper portals."])
        // The table is empty again (just the frame).
        let out = await notes(mapper.handleCommand("mapper portals"))
        #expect(!out.contains { $0.contains("nexus") })
    }

    @Test("a confirm with nothing armed is rejected")
    func purgeConfirmUnarmed() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper purge portals confirm"))
            == ["Failed to confirm ''. Aborting."])
    }

    // MARK: - delete / change by index or keywords

    @Test("delete portal by #index reports the keywords + index")
    func deleteByIndex() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0")
        #expect(await notes(mapper.handleCommand("mapper delete portal #1"))
            == ["Deleted mapper portal index #1 with keywords 'nexus'."])
    }

    @Test("delete of an unknown portal fails with the reference message")
    func deleteUnknown() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper delete portal nope"))
            == ["DELETE FAILED: Did not find a mapper portal with keywords 'nope'."])
    }

    @Test("delete of an out-of-range index fails with the reference message")
    func deleteBadIndex() async throws {
        let mapper = try await makeMapper()
        let expected = "DELETE FAILED: Did not find portal #9 in the list of portals. "
            + "Try 'mapper portals' to see the list."
        #expect(await notes(mapper.handleCommand("mapper delete portal #9")) == [expected])
    }

    @Test("change portal renames the command")
    func changeCommand() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0")
        #expect(await notes(mapper.handleCommand("mapper change portal {nexus} {warp}"))
            == ["Changed mapper portal to command 'warp'."])
    }

    // MARK: - portalrecall / portallevel by index

    @Test("portalrecall toggles by index with the reference message")
    func portalRecallByIndex() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0")
        #expect(await notes(mapper.handleCommand("mapper portalrecall 1"))
            == ["PORTALRECALL: Recall flag added to portal 'nexus' to 'Aylor Inn'."])
    }

    @Test("portalrecall with no index reports the parameter error")
    func portalRecallNoIndex() async throws {
        let mapper = try await makeMapper()
        let out = await notes(mapper.handleCommand("mapper portalrecall"))
        #expect(out.first?.hasPrefix("PORTALRECALL FAILED: The required parameter") == true)
    }

    @Test("portallevel sets the lock by index with the reference message")
    func portalLevelByIndex() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0")
        #expect(await notes(mapper.handleCommand("mapper portallevel 1 60"))
            == ["Portal 'nexus' to 'Aylor Inn' given minimum level lock of 60."])
    }

    // MARK: - bounceportal / bouncerecall

    @Test("bounceportal set/show/clear, and rejects a recall portal")
    func bouncePortal() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0") // #1 regular
        _ = await mapper.handleCommand("mapper fullportal {recall} {100} 0") // #2 recall
        #expect(await notes(mapper.handleCommand("mapper bounceportal")) ==
            ["BOUNCEPORTAL: Not currently set."])
        #expect(await notes(mapper.handleCommand("mapper bounceportal 1"))
            ==
            [
                "BOUNCEPORTAL: Set portal #1 (nexus) as the bounce portal for portal-friendly norecall rooms."
            ])
        #expect(await notes(mapper.handleCommand("mapper bounceportal")) ==
            ["BOUNCEPORTAL: Currently set to 'nexus'"])
        // A recall portal can't be a bounce portal.
        #expect(await notes(mapper.handleCommand("mapper bounceportal 2"))
            .first?.hasPrefix("BOUNCEPORTAL FAILED: Portal #2 is a recall portal") == true)
        #expect(await notes(mapper.handleCommand("mapper bounceportal clear")) == ["BOUNCEPORTAL: cleared."])
    }

    @Test("a designated bounce portal is marked with * in the table")
    func bounceMarker() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0")
        _ = await mapper.handleCommand("mapper bounceportal 1")
        let out = await notes(mapper.handleCommand("mapper portals"))
        // The row's leading marker cell now carries '*' instead of a space.
        #expect(out.contains { $0.hasPrefix("|*  1 |") })
    }

    @Test("a bounce designation persists across a fresh Mapper on the same store")
    func bouncePersists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-bounce-persist-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let mapper = try Mapper(store: MapperStore(url: url))
            _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
            _ = await mapper.ingest(
                package: "room.info",
                json: #"{"num":100,"name":"Aylor Inn","zone":"aylor","exits":{}}"#
            )
            _ = await mapper.ingest(
                package: "room.info",
                json: #"{"num":1,"name":"Square","zone":"aylor","exits":{}}"#
            )
            _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0")
            _ = await mapper.handleCommand("mapper bounceportal 1")
            #expect(await mapper.bouncePortalDir == "nexus")
        }
        // A fresh Mapper over the same on-disk store restores the designation.
        let reopened = try Mapper(store: MapperStore(url: url))
        #expect(await reopened.bouncePortalDir == "nexus")
    }

    @Test("bouncerecall requires a recall portal")
    func bounceRecall() async throws {
        let mapper = try await makeMapper()
        _ = await mapper.handleCommand("mapper fullportal {nexus} {100} 0") // #1 regular (not recall)
        #expect(await notes(mapper.handleCommand("mapper bouncerecall 1"))
            .first?.hasPrefix("BOUNCERECALL FAILED: Portal #1 is not a recall portal") == true)
    }
}

/// Captures the last ``ScriptDialog`` request a provider received, so a test can
/// assert the prompt's shape after the (synchronous, off-task) provider call.
private final class DialogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScriptDialog?
    var value: ScriptDialog? {
        lock.withLock { stored }
    }

    func store(_ dialog: ScriptDialog) {
        lock.withLock { stored = dialog }
    }
}
