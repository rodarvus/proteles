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

    @Test("Miniwindow use is a caveat (commands work; the custom panel doesn't show)")
    func miniwindowCaveat() throws {
        let r = try report("""
        function OnPluginInstall() WindowCreate("w", 0, 0, 100, 100, 1, 0, 0) end
        """)
        // A self-drawn window is a limitation, not a blocker — the plugin's
        // commands/automations still run, so this is "works with caveats".
        #expect(r.verdict == .worksWithCaveats)
        #expect(r.findings.contains { $0.severity == .warning && $0.message.contains("window") })
    }

    @Test("EnableTrigger is fully supported (no longer flagged a caveat)")
    func enableTriggerSupported() throws {
        // EnableTrigger/Timer/Group route to the host engines now — they were
        // stale "no-op pending" warnings before the dinv/S&D work landed.
        let r = try report("""
        function go() EnableTrigger("t", true); Note("done") end
        """)
        #expect(r.verdict == .supported)
        #expect(r.findings.allSatisfy { $0.severity == .ok })
    }

    @Test("AddTriggerEx is supported; a script AddTimer is the one real caveat")
    func runtimeAutomationsClassification() throws {
        // AddTriggerEx/AddAlias are real now (so: supported, no warning).
        let triggers = try report(#"function go() AddTriggerEx("t","^x$","",0,-1,0,"","fn",12,100) end"#)
        #expect(triggers.verdict == .supported)
        // AddTimer becomes a one-shot, so a repeating script timer is a caveat.
        let timer = try report(#"function go() AddTimer("t",0,0,5,"",0,"fn") end"#)
        #expect(timer.verdict == .worksWithCaveats)
        #expect(timer.findings.contains { $0.severity == .warning && $0.message.contains("once") })
    }

    @Test("A plugin that loads companion files is steered to “Add Local…”")
    func companionFilesHint() throws {
        let r = try report(#"dofile(GetPluginInfo(GetPluginID(), 20) .. "x_db.lua")"#)
        #expect(r.findings.contains { $0.severity == .warning && $0.message.contains("Add Local") })
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

    @Test("ColourNote is a supported call (whole-word, not a substring trip)")
    func wordBoundary() throws {
        // ColourNote is fully supported; "Note" must not double-count inside
        // "ColourNote" — so the single call is counted exactly once.
        let r = try report(#"function f() ColourNote("white", "", "x") end"#)
        #expect(r.verdict == .supported)
        #expect(r.findings.contains { $0.message.contains("Uses 1 supported") && $0.severity == .ok })
    }
}
