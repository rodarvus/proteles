import Foundation
@testable import MudCore
import Testing

/// Phase 8 of the mapper-fidelity work: the sectioned `mapper help`, ported from
/// the reference `aard_GMCP_mapper.xml` `OnHelp()`.
@Suite("Mapper — sectioned help (Phase 8)")
struct MapperHelpTests {
    private func makeMapper() throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapperHelp-\(UUID().uuidString).db")
        return try Mapper(store: MapperStore(url: url))
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { segs.map(\.text).joined() } else { nil }
        }
    }

    @Test("mapper help shows the index with the section list")
    func helpIndex() async throws {
        let mapper = try makeMapper()
        let out = await notes(mapper.handleCommand("mapper help"))
        #expect(out.contains { $0.hasSuffix("[GMCP Mapper Help]") })
        #expect(out.contains { $0.contains("Mapper Help Index") })
        #expect(out.contains(" mapper help config        --> Commands for configuring the mapper"))
        #expect(out.contains(" mapper help search <txt>  --> Searches through help lines looking for a"))
    }

    @Test("bare mapper also shows the index")
    func bareMapper() async throws {
        let mapper = try makeMapper()
        #expect(await notes(mapper.handleCommand("mapper")).contains { $0.contains("Mapper Help Index") })
    }

    @Test("mapper help moving shows the MOVING section")
    func helpSection() async throws {
        let mapper = try makeMapper()
        let out = await notes(mapper.handleCommand("mapper help moving"))
        #expect(out.contains("===== MOVING ====================>"))
        #expect(out.contains("mapper goto <room id>          --> Run to a room by its room number"))
        #expect(out.contains("mapper resume                  --> Initiate a new run to the previous target"))
        // Only the requested section — not the portals header.
        #expect(!out.contains("===== PORTAL ACTIONS ============>"))
    }

    @Test("mapper help all shows every section")
    func helpAll() async throws {
        let mapper = try makeMapper()
        let out = await notes(mapper.handleCommand("mapper help all"))
        for header in [
            "===== CONFIGURATION =============>",
            "===== EXIT ACTIONS ==============>",
            "===== PORTAL ACTIONS ============>",
            "===== SEARCHING =================>",
            "===== EXPLORING =================>",
            "===== MOVING ====================>",
            "===== UTILITIES =================>"
        ] {
            #expect(out.contains(header))
        }
    }

    @Test("mapper help search lists matching help lines")
    func helpSearch() async throws {
        let mapper = try makeMapper()
        let out = await notes(mapper.handleCommand("mapper help search bouncerecall"))
        #expect(out.contains("Searching help for: bouncerecall"))
        #expect(out.contains("===== PORTAL ACTIONS ============>"))
        #expect(out.contains { $0.contains("mapper bouncerecall <index>") })
        // A non-matching section's header shouldn't appear.
        #expect(!out.contains("===== MOVING ====================>"))
    }

    @Test("an unknown help topic falls back to the index")
    func helpUnknown() async throws {
        let mapper = try makeMapper()
        #expect(await notes(mapper.handleCommand("mapper help wibble"))
            .contains { $0.contains("Mapper Help Index") })
    }
}
