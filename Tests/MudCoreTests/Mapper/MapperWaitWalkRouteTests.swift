import Foundation
@testable import MudCore
import Testing

/// The mapper's emission for the faithful `ExecuteWithWaits` movement protocol:
/// every walk is wrapped in the `{begin running}`/`{end running}` markers, and a
/// custom-exit segment that embeds `wait(N)` becomes a `.walkWithWaits` (paced
/// session-side) instead of a raw `.execute` that would leak `wait(1)` to the
/// MUD. Regression cover for the hunt-walk `wait(1)` → "Unknown command" bug.
@Suite("Mapper — wait-walk routing (ExecuteWithWaits)")
struct MapperWaitWalkRouteTests {
    private func newMapper() throws -> (Mapper, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-waitwalk-\(UUID().uuidString).db")
        return try (Mapper(store: MapperStore(url: url)), url)
    }

    /// `segmentEffects` routes a wait-bearing command to `.walkWithWaits`
    /// (carrying the final-segment end-running flag), and a plain command to
    /// `.execute` plus the `{end running}` marker on the final segment.
    @Test("segmentEffects routes wait-bearing vs plain commands")
    func segmentRouting() async throws {
        let (mapper, url) = try newMapper()
        defer { try? FileManager.default.removeItem(at: url) }

        let waitSeg = Speedwalk.Segment(command: "hunt crystal;wait(1)", expectUID: "200")
        #expect(await mapper.segmentEffects(waitSeg, isFinal: true) == [
            .walkWithWaits(command: "hunt crystal;wait(1)", emitEndRunning: true)
        ])
        #expect(await mapper.segmentEffects(waitSeg, isFinal: false) == [
            .walkWithWaits(command: "hunt crystal;wait(1)", emitEndRunning: false)
        ])

        let plainSeg = Speedwalk.Segment(command: "run e", expectUID: "200")
        #expect(await mapper.segmentEffects(plainSeg, isFinal: true) == [
            .execute("run e"),
            .sendNoEcho(Mapper.endRunningMarker)
        ])
        #expect(await mapper.segmentEffects(plainSeg, isFinal: false) == [.execute("run e")])
    }

    /// A `mapper goto` whose route is a single `wait()`-bearing custom exit emits
    /// the begin-running marker then a `.walkWithWaits` — and NEVER an `.execute`
    /// carrying the raw `wait(1)` (the live bug, which `;`-split it onto the
    /// wire). Fails without the fix.
    @Test("A goto through a wait() custom exit emits walkWithWaits, not raw execute")
    func gotoThroughWaitCexit() async throws {
        let (mapper, url) = try newMapper()
        defer { try? FileManager.default.removeItem(at: url) }

        // Two rooms; the ONLY link from 100 to 200 is a hunt-walk custom exit.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":200,"name":"Target","zone":"z","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":100,"name":"Start","zone":"z","exits":{}}"#
        )
        let cmd = "hunt crystal;wait(1);hunt crystal;wait(1)"
        _ = await mapper.handleCommand("mapper fullcexit {\(cmd)} 100 200")
        // Re-establish position in 100 after the cexit insert.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":100,"name":"Start","zone":"z","exits":{}}"#
        )

        let effects = await mapper.handleCommand("mapper goto 200")
        // Begin-running first, then the paced walk — no leaked execute/send of
        // the raw command.
        #expect(effects.contains(.sendNoEcho(Mapper.beginRunningMarker)))
        #expect(effects.contains(.walkWithWaits(command: cmd, emitEndRunning: true)))
        for effect in effects {
            if case .execute(let text) = effect {
                #expect(!text.contains("wait("), "raw wait leaked into execute: \(text)")
            }
            if case .send(let text) = effect {
                #expect(!text.contains("hunt crystal"), "raw hunt-walk leaked into send: \(text)")
            }
        }
    }
}
