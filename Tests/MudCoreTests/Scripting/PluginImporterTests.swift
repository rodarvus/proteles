import Foundation
@testable import MudCore
import Testing

@Suite("PluginImporter — compatibility diagnostics")
struct PluginImporterTests {
    private func report(_ script: String, triggers: String = "") throws -> PluginImportReport {
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.test.p" name="Test Plugin" author="Me" version="1.2"/>
        \(triggers)
        <script><![CDATA[ \(script) ]]></script>
        </muclient>
        """)
        return PluginImporter.analyze(plugin)
    }

    @Test("A plugin using only supported calls is reported as supported")
    func supportedPlugin() throws {
        let r = try report("""
        function OnPluginInstall() Note("hi"); Send("look"); SetVariable("x", "1") end
        """)
        #expect(r.name == "Test Plugin")
        #expect(r.author == "Me")
        #expect(r.version == "1.2")
        #expect(r.verdict == .supported)
        #expect(r.findings.allSatisfy { $0.severity == .ok })
    }

    @Test("Miniwindow use makes the plugin unsupported")
    func miniwindowUnsupported() throws {
        let r = try report("""
        function OnPluginInstall() WindowCreate("w", 0, 0, 100, 100, 1, 0, 0) end
        """)
        #expect(r.verdict == .unsupported)
        #expect(r.findings.contains { $0.severity == .error && $0.message.contains("miniwindow") })
    }

    @Test("A partial API (EnableTrigger) yields caveats, not a hard failure")
    func partialCaveats() throws {
        let r = try report("""
        function go() EnableTrigger("t", true); Note("done") end
        """)
        #expect(r.verdict == .worksWithCaveats)
        #expect(r.findings.contains { $0.severity == .warning && $0.message.contains("EnableTrigger") })
    }

    @Test("require of a bundled lib is OK; an unknown lib is a caveat")
    func requireClassification() throws {
        let bundled = try report(#"require "gmcphelper""#)
        #expect(bundled.findings.contains { $0.severity == .ok && $0.message.contains("gmcphelper") })

        let unknown = try report(#"require "some_random_lib""#)
        #expect(unknown.verdict == .worksWithCaveats)
        #expect(unknown.findings.contains {
            $0.severity == .warning && $0.message.contains("some_random_lib")
        })
    }

    @Test("Counts come from the parsed plugin")
    func counts() throws {
        let r = try report(
            "x = 1",
            triggers: """
            <triggers>
            <trigger match="a" send_to="12"><send>Note("a")</send></trigger>
            <trigger match="b" send_to="12"><send>Note("b")</send></trigger>
            </triggers>
            """
        )
        #expect(r.triggerCount == 2)
        #expect(r.aliasCount == 0)
    }

    @Test("ColourNote whole-word match doesn't trip on substrings")
    func wordBoundary() throws {
        // "Note" must not match inside "ColourNote".
        let r = try report(#"function f() ColourNote("white", "", "x") end"#)
        #expect(r.findings.contains { $0.message.contains("ColourNote") && $0.severity == .warning })
    }
}
