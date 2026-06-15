import Foundation
@testable import MudCore
import Testing

/// `mapper lockexit` must accept a full direction word ("north"), not only the
/// abbreviation ("n") that the exits table is keyed by — the live bug where
/// `mapper lockexit north 1` reported "No 'north' exit from here" despite an
/// `n` exit existing.
@Suite("Mapper — lockexit direction normalization")
struct MapperLockExitTests {
    /// A mapper whose current room (1) has a single `n` exit to room 2.
    private func mapperWithNorthExit() async throws -> (Mapper, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-lockexit-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"North","zone":"z","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Here","zone":"z","exits":{"n":2}}"#
        )
        return (mapper, url)
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { segs.map(\.text).joined() } else { nil }
        }
    }

    @Test("lockexit accepts a full direction word (north → the stored 'n' exit)")
    func fullWord() async throws {
        let (mapper, url) = try await mapperWithNorthExit()
        defer { try? FileManager.default.removeItem(at: url) }
        let effects = await mapper.handleCommand("mapper lockexit north 1")
        let out = notes(effects)
        #expect(out.contains { $0.contains("locked to level 1") })
        #expect(!out.contains { $0.contains("No 'north' exit") })
    }

    @Test("lockexit still accepts the abbreviation")
    func abbreviation() async throws {
        let (mapper, url) = try await mapperWithNorthExit()
        defer { try? FileManager.default.removeItem(at: url) }
        let effects = await mapper.handleCommand("mapper lockexit n 1")
        #expect(notes(effects).contains { $0.contains("locked to level 1") })
    }

    /// Decisive: does locking an exit actually exclude it from routing? Player
    /// level is 0 here (no char.status), so an exit locked to level 1 must be
    /// gated out — `goto` should find no route instead of stepping through it.
    @Test("a locked exit is excluded from routing below its level")
    func lockedExitExcludedFromRoute() async throws {
        let (mapper, url) = try await mapperWithNorthExit() // room 1 —n→ 2, level 0
        defer { try? FileManager.default.removeItem(at: url) }
        func walked(_ effects: [ScriptEffect]) -> Bool {
            effects.contains { if case .execute = $0 { true } else { false } }
        }
        // Baseline: routes north.
        let baseline = await mapper.handleCommand("mapper goto 2")
        #expect(walked(baseline))
        // Lock n to level 1; player level 0 → n must be gated out.
        _ = await mapper.handleCommand("mapper lockexit n 1")
        let afterLock = await mapper.handleCommand("mapper goto 2")
        #expect(!walked(afterLock))
    }
}
