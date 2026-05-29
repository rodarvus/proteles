import Foundation
@testable import MudCore
import Testing

@Suite("Search-and-Destroy — vendored assets")
struct SearchAndDestroyAssetsTests {
    /// The fixture install dir, read directly via the `in:` accessors so this
    /// suite never mutates the shared ``SearchAndDestroyAssets/installDirectory``
    /// global (which would race other S&D suites under `--parallel`).
    let dir: URL

    init() throws {
        dir = try #require(SnDFixture.directory, "S&D test fixture missing")
    }

    @Test("core.lua is present and intact (key functions extracted verbatim)")
    func coreIntact() throws {
        let core = try #require(SearchAndDestroyAssets.core(in: dir))
        #expect(core.count > 100_000) // the full script, not a fragment
        // Markers from the original logic survive the CDATA extraction.
        #expect(core.contains("function init_plugin"))
        #expect(core.contains("function migrate_database"))
        #expect(core.contains("function OnPluginBroadcast"))
        // The CDATA delimiters must NOT be in the extracted Lua.
        #expect(!core.contains("<![CDATA["))
        #expect(!core.contains("]]>"))
    }

    @Test("S&D data modules load from the install dir")
    func helpers() {
        let modules = SearchAndDestroyAssets.helperModules(in: dir)
        for name in ["constants", "areaReferences", "sqlSetup", "tablesSetup"] {
            #expect(modules[name]?.isEmpty == false, "missing S&D module: \(name)")
        }
        // areaReferences holds the area table we reuse as-is.
        #expect(SearchAndDestroyAssets.lua("areaReferences", in: dir)?.contains("areaTable") == true)
    }

    @Test("Gammon's wait/check helpers are bundled separately (not part of S&D)")
    func gammonHelpers() {
        #expect(MUSHHelperAssets.lua("wait")?.isEmpty == false)
        #expect(MUSHHelperAssets.lua("check")?.isEmpty == false)
        #expect(MUSHHelperAssets.modules["wait"] != nil)
    }

    @Test("The normalised plugin XML is available for automation extraction")
    func pluginXML() throws {
        let xml = try #require(SearchAndDestroyAssets.pluginXML(in: dir))
        #expect(xml.contains("<aliases>"))
        #expect(xml.contains("Search_and_Destroy"))
    }
}
