import Foundation
@testable import MudCore
import Testing

/// Segmented-walk behaviour: a route that uses a portal must not fire the
/// follow-on `run` until the portal lands (the live xcp/portal bug). Kept in
/// its own suite so ``MapperCommandTests`` stays within the type-length budget.
@Suite("Mapper — segmented walk (portal timing)")
struct MapperWalkTests {
    private func walkCommands(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { if case .execute(let text) = $0 { text } else { nil } }
    }

    /// Regression: a goto whose route uses a portal must NOT fire the follow-on
    /// `run` until the portal lands. The live bug fired the whole speedwalk at
    /// once, so the post-portal `run` reached the MUD before the whoosh, walked
    /// from the wrong room, and aborted ("Alas, you cannot go that way"). The
    /// goto should emit only the portal command; the `run` is released on the
    /// destination `room.info`. Fails (run leaks into the goto) without the fix.
    @Test("A portal goto withholds the follow-on walk until the portal lands")
    func portalGotoWaitsForArrival() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-walk-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let mapper = try Mapper(store: MapperStore(url: url))

        // Rooms: 14 is the portal destination (south → 20); 1 is the start with
        // no normal exits, so the ONLY route to 20 is portal → 14 → s → 20.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":20,"name":"Target","zone":"z","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":14,"name":"PortalDest","zone":"z","exits":{"s":20}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Start","zone":"z","exits":{}}"#
        )
        // Register a from-anywhere portal whose use-command routes to dinv.
        _ = await mapper.handleCommand("mapper fullportal {dinv portal use 999} {14}")
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Start","zone":"z","exits":{}}"#
        )

        // goto emits ONLY the portal command — the `run s` must be withheld.
        let gotoCommands = await walkCommands(mapper.handleCommand("mapper goto 20"))
        #expect(
            gotoCommands == ["dinv portal use 999"],
            "goto should emit only the portal; got \(gotoCommands)"
        )

        // Still in room 1 (no room.info yet): nothing is released.
        #expect(await mapper.advanceWalk().isEmpty, "walk advanced before the portal landed")

        // The portal lands: room.info for 14 → the follow-on `run s` is released.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":14,"name":"PortalDest","zone":"z","exits":{"s":20}}"#
        )
        #expect(
            await walkCommands(mapper.advanceWalk()) == ["run s"],
            "follow-on walk not released after arrival"
        )
    }
}
