import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclient world-level aliases → Proteles")
struct MUSHclientAliasImportTests {
    @Test("parses <alias> elements (match + send + send_to) from a world file")
    func parsesAliases() throws {
        let mcl = """
        <muclient><world name="W" site="h" port="23"></world>
        <aliases>
          <alias match="gg *" enabled="y" send_to="10" sequence="100"><send>cast 'goodbye' %1</send></alias>
          <alias match="kk" enabled="n" send_to="0" sequence="50"><send>kill rat</send></alias>
        </aliases></muclient>
        """
        let world = try #require(MUSHclientWorldParser.parse(Data(mcl.utf8)))
        #expect(world.aliases.count == 2)
        let aliases = MUSHclientScriptMapping.aliases(from: world.aliases)
        #expect(aliases.count == 2)
        let gg = try #require(aliases.first { $0.pattern == .wildcard("gg *") })
        #expect(gg.sendText == "cast 'goodbye' %1")
        #expect(gg.sendTo == .execute) // send_to=10 → eSendToExecute
        #expect(gg.enabled)
        let kk = try #require(aliases.first { $0.pattern == .wildcard("kk") })
        #expect(kk.sendTo == .world && !kk.enabled && kk.sequence == 50)
    }
}

@Suite("MUSHclient aliases — real install", .enabled(if: FileManager.default.fileExists(
    atPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows/worlds/Aardwolf.mcl"
)))
struct MUSHclientRealAliasTests {
    @Test("the live world's 14 aliases all map to Proteles aliases")
    func real() throws {
        let url = URL(fileURLWithPath:
            "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows/worlds/Aardwolf.mcl")
        let world = try #require(MUSHclientWorldParser.parse(Data(contentsOf: url)))
        #expect(world.aliases.count == 14)
        let mapped = MUSHclientScriptMapping.aliases(from: world.aliases)
        #expect(mapped.count == 14)
        #expect(mapped.allSatisfy { $0.sendText?.isEmpty == false })
    }
}
