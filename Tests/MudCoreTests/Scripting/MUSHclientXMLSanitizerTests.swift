import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclientXMLSanitizer — lenient attribute escaping")
struct MUSHclientXMLSanitizerTests {
    /// The live-bug repro: a PCRE named-group regex in a trigger `match` has raw
    /// `<`/`>` in an attribute value, which strict XMLParser rejects. The
    /// sanitizer escapes them so the plugin parses and the pattern survives
    /// intact (Hadar_Spellups + ~10 other live plugins hit this).
    @Test("A (?<name>) regex in match= imports, pattern preserved")
    func namedGroupRegexImports() throws {
        let xml = """
        <?xml version="1.0" encoding="iso-8859-1"?>
        <!DOCTYPE muclient>
        <muclient>
        <plugin id="aaaaaaaaaaaaaaaaaaaaaaaa" name="Spellups"/>
        <triggers>
        <trigger enabled="y" regexp="y"
          match="^\\{sfail\\}(?<sn>(-|)[0-9]{1,3})\\,(?<tg>[0-9]{1,3})" send_to="12">
        <send>doit()</send>
        </trigger>
        </triggers>
        <script><![CDATA[ function doit() end ]]></script>
        </muclient>
        """
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        #expect(plugin.name == "Spellups")
        #expect(plugin.triggers.count == 1)
        guard case .regex(let pattern) = plugin.triggers[0].pattern else {
            Issue.record("expected a regex trigger; got \(plugin.triggers[0].pattern)")
            return
        }
        #expect(pattern.contains("(?<sn>"))
        #expect(pattern.contains("(?<tg>"))
    }

    @Test("CDATA script bodies are left verbatim (their <, >, & untouched)")
    func cdataUntouched() throws {
        let xml = """
        <muclient>
        <plugin id="bbbbbbbbbbbbbbbbbbbbbbbb" name="Cdata"/>
        <script><![CDATA[ if a < b and c > d then return e & f end ]]></script>
        </muclient>
        """
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        #expect(plugin.script.contains("a < b and c > d"))
        #expect(plugin.script.contains("e & f"))
    }

    @Test("Already-valid entities aren't double-escaped (idempotent)")
    func entitiesNotDoubleEscaped() {
        let input = Data(#"<t match="a &lt; b &amp; c &#10; d"/>"#.utf8)
        let out = String(decoding: MUSHclientXMLSanitizer.lenientAttributeData(input), as: UTF8.self)
        #expect(out == #"<t match="a &lt; b &amp; c &#10; d"/>"#)
    }

    @Test("A bare & in an attribute is escaped; raw < / > too")
    func bareAmpersandAndAnglesEscaped() {
        let input = Data(#"<t match="x<y & z>w"/>"#.utf8)
        let out = String(decoding: MUSHclientXMLSanitizer.lenientAttributeData(input), as: UTF8.self)
        #expect(out == #"<t match="x&lt;y &amp; z&gt;w"/>"#)
    }

    @Test("A well-formed plugin is unchanged through the sanitizer")
    func wellFormedUnchanged() {
        let xml = #"<muclient><plugin id="c" name="OK"/><script><![CDATA[ x=1 ]]></script></muclient>"#
        let out = String(decoding: MUSHclientXMLSanitizer.lenientAttributeData(Data(xml.utf8)), as: UTF8.self)
        #expect(out == xml)
    }
}
