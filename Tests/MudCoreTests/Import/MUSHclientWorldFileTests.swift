import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclient world-file parse (import)")
struct MUSHclientWorldFileTests {
    private static let mcl = """
    <?xml version="1.0" encoding="iso-8859-1"?>
    <!DOCTYPE muclient>
    <muclient>
    <world name="Aardwolf" site="aardmud.org" port="4050" save_world_automatically="y" />
    <macros>
      <macro name="up" type="send_now" >
      <send>up</send>
      </macro>
      <macro name="north" type="send_now" >
      <send>north</send>
      </macro>
    </macros>
    <!-- plugins -->
    <include name="aard_GMCP_mapper.xml" plugin="y" />
    <include name="dinv\\dinv.xml" plugin="y" />
    <include name="not_a_plugin.xml" />
    </muclient>
    """

    @Test("parses world config, macros, and enabled plugin includes")
    func parsesWorld() throws {
        let world = try #require(MUSHclientWorldParser.parse(Data(Self.mcl.utf8)))
        #expect(world.name == "Aardwolf")
        #expect(world.host == "aardmud.org")
        #expect(world.port == 4050)
        #expect(world.macros == [
            .init(name: "up", send: "up", type: "send_now"),
            .init(name: "north", send: "north", type: "send_now")
        ])
        // Only plugin="y" includes; Windows-style subdir path preserved verbatim.
        #expect(world.pluginIncludes == ["aard_GMCP_mapper.xml", #"dinv\dinv.xml"#])
    }
}

/// Validates the parser against the real captured install when present (skipped
/// on CI / machines without it).
@Suite("MUSHclient world-file — real install", .enabled(if: FileManager.default.fileExists(
    atPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows/worlds/Aardwolf.mcl"
)))
struct MUSHclientWorldFileRealTests {
    @Test("real Aardwolf.mcl: config + 24 macros + 48 enabled plugins")
    func real() throws {
        let url = URL(fileURLWithPath:
            "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows/worlds/Aardwolf.mcl")
        let world = try #require(try MUSHclientWorldParser.parse(Data(contentsOf: url)))
        #expect(world.name == "Aardwolf")
        #expect(world.host == "aardmud.org")
        #expect(world.port == 23) // the world port (chat_port=4050 is a separate attr)
        #expect(!world.username.isEmpty) // autologin character captured
        #expect(world.password != nil) // password decoded for Keychain import (value never asserted)
        #expect(world.macros.count == 24)
        #expect(world.pluginIncludes.count == 48)
        // Subdir plugins preserve their Windows-style path.
        #expect(world.pluginIncludes.contains(#"dinv\dinv.xml"#))
    }
}
