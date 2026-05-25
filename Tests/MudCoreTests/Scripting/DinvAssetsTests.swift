import Foundation
@testable import MudCore
import Testing

@Suite("dinv — vendored assets")
struct DinvAssetsTests {
    @Test("every dinv module is bundled and non-empty")
    func modulesPresent() {
        let modules = DinvAssets.modules
        #expect(modules.count == DinvAssets.moduleNames.count)
        for name in DinvAssets.moduleNames {
            #expect(modules[name]?.isEmpty == false, "missing or empty dinv module: \(name)")
        }
        // The bootstrap + the framework + the heaviest module are present.
        #expect(modules["dinv_init"]?.contains("drlGetPluginStatePath") == true)
        #expect(modules["dinv_dbot"] != nil)
        #expect(modules["dinv_items"] != nil)
    }

    @Test("dinv.xml parses and bootstraps dinv_init via dofile")
    func pluginXMLParses() throws {
        let xml = try #require(DinvAssets.pluginXML)
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        #expect(plugin.id == DinvAssets.pluginID)
        #expect(plugin.name == "dinv")
        // The <script> bootstrap dofiles dinv_init; the dofile target's basename
        // resolves to our registered module.
        #expect(plugin.script.contains("dinv_init.lua"))
        // The command surface comes in as aliases (the `dinv ...` commands).
        #expect(!plugin.aliases.isEmpty)
    }
}
