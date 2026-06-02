import Foundation
@testable import MudCore
import Testing

/// Phase 6 of the mapper-fidelity work: areas/zones/maintenance — `purgezone`,
/// `clearcache`, and `reset`/`resetaard` — checked against the reference
/// `aard_GMCP_mapper.xml` (`map_purgezone`/`map_clearcache`/`reset_aard`).
@Suite("Mapper — areas/zones/maintenance (Phase 6)")
struct MapperMaintenanceTests {
    private func makeMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-maint-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
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

    @Test("purgezone deletes a known area and reports its display name")
    func purgezone() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper purgezone aylor"))
            == ["Purged Aylor from the mapper database."])
        #expect(await mapper.graph.rooms["1"] == nil)
    }

    @Test("purgezone with no/unknown keyword shows the syntax help")
    func purgezoneSyntax() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper purgezone")) == [
            "Syntax: mapper purgezone <keyword>",
            "Try 'mapper areas' for a list of area keywords.",
            ""
        ])
        #expect(await notes(mapper.handleCommand("mapper purgezone nope")).first
            == "Syntax: mapper purgezone <keyword>")
    }

    @Test("clearcache reports the reference message")
    func clearcache() async throws {
        let mapper = try await makeMapper()
        #expect(await notes(mapper.handleCommand("mapper clearcache")) == ["Cleared local room cache."])
    }

    @Test("backup archives the DB into a db_backups/ directory")
    func backup() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Aardwolf.db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)

        let out = await notes(mapper.handleCommand("mapper backup"))
        #expect(out.first?.hasPrefix("Map backed up to db_backups/Aardwolf.") == true)
        let backups = (try? FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("db_backups"), includingPropertiesForKeys: nil
        )) ?? []
        #expect(backups.contains { $0.lastPathComponent.hasPrefix("Aardwolf.") && $0.pathExtension == "db" })
    }

    @Test("reset re-requests the room silently and forgets position")
    func reset() async throws {
        let mapper = try await makeMapper()
        let effects = await mapper.handleCommand("mapper resetaard")
        // Silent (no notes), just the GMCP room request — matching reset_aard.
        #expect(notes(effects).isEmpty)
        #expect(effects.contains {
            if case .sendGMCP(let payload) = $0 { payload == "request room" } else { false }
        })
        #expect(await mapper.currentRoomUID == nil)
    }
}
