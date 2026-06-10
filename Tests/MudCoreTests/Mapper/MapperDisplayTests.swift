import Foundation
@testable import MudCore
import Testing

/// Phase 7 of the mapper-fidelity work: display-window + multi-database commands
/// route to Proteles's native map panel / Databases menu (the project decision),
/// keeping the command names working rather than erroring.
@Suite("Mapper — display & database commands (Phase 7)")
struct MapperDisplayTests {
    private func makeMapper() throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapperDisplay-\(UUID().uuidString).db")
        return try Mapper(store: MapperStore(url: url))
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { segs.map(\.text).joined() } else { nil }
        }
    }

    @Test("display-window commands route to the native panel (no error)")
    func displayCommands() async throws {
        let mapper = try makeMapper()
        for command in [
            "zoom in",
            "hide",
            "show",
            "showroom",
            "updown",
            "underlines on",
            "compact",
            "quicklist"
        ] {
            let out = await notes(mapper.handleCommand("mapper \(command)"))
            #expect(out.count == 1)
            #expect(out.first?.contains("native") == true || out.first?.contains("Proteles") == true)
            // They must NOT fall through to the unknown-command handler.
            #expect(out.first?.contains("Unknown mapper command") != true)
        }
    }

    @Test("mapper textures toggles the area background and persists per-profile")
    func textures() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapperDisplay-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Spot","zone":"z","exits":{}}"#
        )
        #expect(await mapper.useTextures == true) // default on, like the reference
        // On with no texture column → the reference default rides the layout.
        #expect(await mapper.currentLayout().areaTexture == "test5.png")
        _ = await mapper.handleCommand("mapper textures off")
        #expect(await mapper.useTextures == false)
        #expect(await mapper.currentLayout().areaTexture == nil)
        // The flag persists in proteles_meta — a fresh mapper on the same
        // store (a world reload) comes back off.
        let reopened = try Mapper(store: MapperStore(url: url))
        #expect(await reopened.useTextures == false)
    }

    @Test("database reports the active database file (reference wording)")
    func databaseName() async throws {
        let mapper = try makeMapper()
        let out = await notes(mapper.handleCommand("mapper database"))
        #expect(out.first?.hasPrefix("Current mapper database file is ") == true)
        #expect(out.first?.hasSuffix(".db") == true)
    }

    @Test("set database / backups route to the Databases menu")
    func databaseRouting() async throws {
        let mapper = try makeMapper()
        #expect(await notes(mapper.handleCommand("mapper set database other"))
            .first?.contains("Databases menu") == true)
        #expect(await notes(mapper.handleCommand("mapper backups"))
            .first?.contains("Databases menu") == true)
    }
}
