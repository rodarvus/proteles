@testable import MudCore
import Testing

@Suite("Search-and-Destroy — XML normalisation + automation parse")
struct SearchAndDestroyXMLTests {
    init() {
        SnDFixture.install()
    }

    @Test("Escapes < and > only inside attribute values")
    func escapesAttributeAngles() {
        let input = #"<trigger match="^a(?<mob>.+)b$" enabled="y"></trigger>"#
        let out = SearchAndDestroyXML.normalise(input)
        #expect(out.contains("(?&lt;mob&gt;.+)"))
        // The tag delimiters themselves are untouched.
        #expect(out.hasPrefix("<trigger "))
        #expect(out.hasSuffix("></trigger>"))
    }

    @Test("CDATA and element text pass through verbatim")
    func passesThroughCDATAAndText() {
        let input = "<script><![CDATA[ if a < b and b > c then end ]]></script>" +
            "<alias match=\"x\"><send>foo() if 1 < 2 then end</send></alias>"
        let out = SearchAndDestroyXML.normalise(input)
        // CDATA keeps its literal angle brackets.
        #expect(out.contains("if a < b and b > c then end"))
        // Element text (the <send> body) is also untouched.
        #expect(out.contains("foo() if 1 < 2 then end"))
    }

    @Test("Comments pass through verbatim")
    func passesThroughComments() {
        let input = "<!-- a < b > c --><alias match=\"q(?<n>.)\"></alias>"
        let out = SearchAndDestroyXML.normalise(input)
        #expect(out.contains("<!-- a < b > c -->"))
        #expect(out.contains("q(?&lt;n&gt;.)"))
    }

    @Test("Single-quoted attribute values are handled too")
    func handlesSingleQuotes() {
        let input = "<trigger match='a<b>c'></trigger>"
        let out = SearchAndDestroyXML.normalise(input)
        #expect(out.contains("a&lt;b&gt;c"))
    }

    @Test("The vendored S&D XML now parses into the full automation set")
    func parsesVendoredPlugin() throws {
        let xml = try #require(SearchAndDestroyAssets.pluginXML)
        let plugin = try MUSHclientPluginLoader.parse(xml: SearchAndDestroyXML.normalise(xml))

        #expect(plugin.id == SearchAndDestroyHost.pluginID)
        #expect(plugin.name == "Search_and_Destroy")
        // The full corpus: 94 triggers, 98 aliases, 7 timers.
        #expect(plugin.triggers.count == 94)
        #expect(plugin.aliases.count == 98)
        #expect(plugin.timers.count == 7)

        // A named-capture regex survived normalisation byte-for-byte.
        let damage = plugin.triggers.first {
            if case .regex(let pattern) = $0.pattern { return pattern.contains("(?<mob_name>") }
            return false
        }
        #expect(damage != nil)
        // Its script target dispatches to the named core.lua function.
        #expect(damage?.script?.contains("trigger_damage_done") == true)
    }
}
