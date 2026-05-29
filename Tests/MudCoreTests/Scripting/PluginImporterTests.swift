import Foundation
@testable import MudCore
import Testing

@Suite("PluginImporter — compatibility diagnostics")
struct PluginImporterTests {
    private func report(
        _ script: String,
        triggers: String = "",
        availableFiles: Set<String> = []
    ) throws -> PluginImportReport {
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.test.p" name="Test Plugin" author="Me" version="1.2"/>
        \(triggers)
        <script><![CDATA[ \(script) ]]></script>
        </muclient>
        """)
        return PluginImporter.analyze(plugin, availableFiles: availableFiles)
    }

    @Test("A plugin using only supported calls is Ready with no findings")
    func supportedPlugin() throws {
        let r = try report("""
        function OnPluginInstall() Note("hi"); Send("look"); SetVariable("x", "1") end
        """)
        #expect(r.name == "Test Plugin")
        #expect(r.author == "Me")
        #expect(r.version == "1.2")
        #expect(r.verdict == .ready)
        #expect(r.findings.isEmpty)
    }

    @Test("Miniwindow use is a soft note — still Ready (commands work; panel won't draw)")
    func miniwindowNote() throws {
        let r = try report("""
        function OnPluginInstall() WindowCreate("w", 0, 0, 100, 100, 1, 0, 0) end
        """)
        // A self-drawn window doesn't stop the plugin working, so it stays Ready
        // and the heads-up is an info note, not a verdict-lowering warning.
        #expect(r.verdict == .ready)
        #expect(r.findings.contains { $0.severity == .info && $0.message.contains("pop-up window") })
    }

    @Test("EnableTrigger and AddTriggerEx are fully supported (no findings)")
    func runtimeAutomationsSupported() throws {
        let enable = try report(#"function go() EnableTrigger("t", true); Note("done") end"#)
        #expect(enable.verdict == .ready)
        #expect(enable.findings.isEmpty)

        let add = try report(#"function go() AddTriggerEx("t","^x$","",0,-1,0,"","fn",12,100) end"#)
        #expect(add.verdict == .ready)
        #expect(add.findings.isEmpty)
    }

    @Test("A script AddTimer no longer warns — one-shot timers work like MUSHclient")
    func addTimerSilent() throws {
        // We can't tell a one-shot from a repeating timer statically, and a
        // one-shot works exactly as it does in MUSHclient — so no blanket note.
        let r = try report(#"function go() AddTimer("t",0,0,5,"",0,"fn") end"#)
        #expect(r.verdict == .ready)
        #expect(r.findings.isEmpty)
    }

    @Test("A required helper present in the folder resolves — Ready, no warning")
    func helperPresentResolves() throws {
        let r = try report(#"require "aardutils""#, availableFiles: ["aardutils.lua"])
        #expect(r.verdict == .ready)
        #expect(r.findings.isEmpty)
    }

    @Test("A required helper that wasn't included is one actionable warning")
    func helperMissingWarns() throws {
        let r = try report(#"local u = require "aardutils"; local v = require "var""#)
        #expect(r.verdict == .needsAttention)
        let warnings = r.findings.filter { $0.severity == .warning }
        #expect(warnings.count == 1) // consolidated, not one-per-file
        #expect(warnings.first?.message.contains("aardutils.lua") == true)
        #expect(warnings.first?.message.contains("var.lua") == true)
        #expect(warnings.first?.message.contains("whole plugin folder") == true)
    }

    @Test("require of a bundled lib needs nothing — Ready, no findings")
    func bundledLibSilent() throws {
        let r = try report(#"require "gmcphelper"; require "serialize""#)
        #expect(r.verdict == .ready)
        #expect(r.findings.isEmpty)
    }

    @Test("Lua standard libraries are never reported as missing files")
    func standardLibrariesResolve() throws {
        // The earlier analyzer flagged `require "math"` as a missing `math.lua`.
        let r = try report(#"require "string"; require "math"; require "table""#)
        #expect(r.verdict == .ready)
        #expect(r.findings.isEmpty)
    }

    @Test("A dofile'd companion file is resolved against the folder")
    func dofileCompanionResolution() throws {
        let script = #"dofile(GetPluginInfo(GetPluginID(), 20) .. "x_db.lua")"#
        // Missing → warned.
        let missing = try report(script)
        #expect(missing.verdict == .needsAttention)
        #expect(missing.findings.contains { $0.message.contains("x_db.lua") })
        // Present in the folder → clean.
        let present = try report(script, availableFiles: ["x_db.lua"])
        #expect(present.verdict == .ready)
        #expect(present.findings.isEmpty)
    }

    @Test("luacom is a soft note about a Windows-only feature — still Ready")
    func luacomNote() throws {
        let r = try report(#"luacom.CreateObject("SAPI.SpVoice")"#)
        #expect(r.verdict == .ready)
        #expect(r.findings.contains { $0.severity == .info && $0.message.contains("Windows-only") })
    }

    @Test("async (network) is a soft note, not a missing file")
    func asyncNote() throws {
        let r = try report(#"local a = require "async""#)
        #expect(r.verdict == .ready)
        #expect(r.findings.contains { $0.severity == .info && $0.message.contains("internet") })
        #expect(!r.findings.contains { $0.severity == .warning })
    }

    @Test("The dependency-nag (checkplugin / aard_requirements) is stubbed, not warned")
    func dependencyNagResolves() throws {
        // mudbin's `OnPluginListChanged` dofiles `lua/aard_requirements.lua`,
        // which requires `checkplugin` — both are no-op stubs in Proteles, so
        // neither should be flagged as a missing file.
        let r = try report("""
        require "checkplugin"
        function OnPluginListChanged() dofile("lua/aard_requirements.lua") end
        """)
        #expect(r.verdict == .ready)
        #expect(r.findings.isEmpty)
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
}
