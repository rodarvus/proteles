import Foundation
@testable import MudCore
import Testing

/// Compat-shim additions surfaced by auditing real community plugins (loaded +
/// run through the shim): `check`, `SaveState`, the GMCP-handler `gmcpval`
/// CallPlugin bridge, `dofile` Windows-path normalisation, and a sandboxed `io`.
@Suite("LuaRuntime — community-plugin shim additions")
struct ShimCompatAdditionsTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("require returns an already-loaded stdlib library (string/math)")
    func requireStdlib() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        proteles.echo(tostring(require("string") == string))
        proteles.echo(tostring(require("math") == math))
        """)
        #expect(effects == [.echo("true"), .echo("true")])
    }

    @Test("Accelerator / AcceleratorTo register a MacroEngine binding via the registrar")
    func acceleratorBridge() async throws {
        let lua = try await shimmed()
        let box = MacroBox()
        await lua.setAcceleratorRegistrar { box.append($0) }
        let effects = try await lua.run("""
        proteles.echo(tostring(AcceleratorTo("Ctrl+P", "score", 12) == error_code.eOK))
        Accelerator("Alt+F4", "quit")
        """)
        #expect(effects == [.echo("true")])
        let macros = box.all
        #expect(macros.count == 2)
        // AcceleratorTo with sendto.script (12) → run `send` as Lua.
        #expect(macros.first?.action == .script("score"))
        #expect(macros.first?.chord.modifiers.contains(.control) == true)
        // Accelerator (no sendto) → send as a command.
        #expect(macros.last?.action == .command("quit"))
        #expect(macros.last?.chord.isFunctionKey == true)
    }

    /// Thread-safe sink for the test's accelerator registrar (the host calls it
    /// synchronously on the script executor).
    final class MacroBox: @unchecked Sendable {
        private let lock = NSLock()
        private var macros: [Macro] = []
        func append(_ macro: Macro) {
            lock.withLock { macros.append(macro) }
        }

        var all: [Macro] {
            lock.withLock { macros }
        }
    }

    @Test("SendSpecial honours Echo and defaults to no-echo (one-arg form)")
    func sendSpecial() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        proteles.echo(tostring(SendSpecial("score") == error_code.eOK)) -- one arg → no echo
        SendSpecial("look", true)   -- Echo true → echoed send
        SendSpecial("quaff blue", false, true, true, true) -- queue/log/history ignored
        """)
        #expect(effects == [
            .sendNoEcho("score"), // the send happens inside the call, before echo prints eOK
            .echo("true"),
            .send("look"),
            .sendNoEcho("quaff blue")
        ])
    }

    @Test("checkplugin / aard_requirements load as no-ops (the dependency nag)")
    func dependencyNagStub() async throws {
        let lua = try await shimmed()
        // Mirrors mudbin: require checkplugin, then dofile aard_requirements via
        // the basename fallback. Both resolve and run without error.
        let effects = try await lua.run("""
        require "checkplugin"
        do_plugin_check_now("50f4e1fc89999ce02a216a3c", "aard_requirements")
        dofile("lua/aard_requirements.lua")
        proteles.echo("loaded")
        """)
        #expect(effects == [.echo("loaded")])
    }

    @Test("utils dialogs route through the injected provider and map results")
    func utilsDialogs() async throws {
        let lua = try await shimmed()
        await lua.setDialogProvider { request in
            switch request {
            case .message: .button("yes")
            case .input(_, _, let def, let multiline): .text((multiline ? "EDITED:" : "INPUT:") + def)
            case .choose: .index(2)
            case .openFile(_, let directory): .path(directory ? "/folder" : "/file.txt")
            }
        }
        let effects = try await lua.run("""
        proteles.echo(utils.msgbox("q?", "Title", 4))
        proteles.echo(utils.inputbox("name?", "T", "joe"))
        proteles.echo(utils.editbox("Data", "Edit", "abc"))
        proteles.echo(tostring(utils.choose("pick", "T", {"a", "b", "c"})))
        proteles.echo(utils.filepicker())
        proteles.echo(utils.directorypicker())
        """)
        #expect(effects == [
            .echo("yes"), .echo("INPUT:joe"), .echo("EDITED:abc"),
            .echo("2"), .echo("/file.txt"), .echo("/folder")
        ])
    }

    @Test("With no provider, msgbox returns ok and inputbox/editbox return nil")
    func utilsDialogsNoProvider() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        proteles.echo(utils.msgbox("q?", "T", 0))
        proteles.echo(tostring(utils.editbox("Data", "Edit", "abc")))
        """)
        #expect(effects == [.echo("ok"), .echo("nil")])
    }

    @Test("check() passes eOK through and errors on a non-eOK code")
    func checkGuard() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        proteles.echo(tostring(check(error_code.eOK)))
        proteles.echo(tostring((pcall(function() check(30001) end))))
        """)
        #expect(effects == [.echo("0"), .echo("false")])
    }

    @Test("SaveState() runs OnPluginSaveState so its SetVariables persist")
    func saveStateRunsCallback() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        function OnPluginSaveState() SetVariable("saved", "yes") end
        SaveState()
        proteles.echo(GetVariable("saved") or "nil")
        """)
        #expect(effects == [.echo("yes")])
    }

    @Test("CallPlugin(gmcp handler, gmcpval, path) returns a loadstring-able literal")
    func gmcpvalCallPluginBridge() async throws {
        let lua = try await shimmed()
        await lua.applyGMCP(package: "char.status", json: #"{"state":3}"#)
        let effects = try await lua.run("""
        local _, s = CallPlugin("3e7dedbe37e44942dd46d264", "gmcpval", "char.status")
        assert(loadstring("gmcpdata = " .. s))()
        proteles.echo(tostring(gmcpdata.state))
        """)
        #expect(effects == [.echo("3")])
    }

    @Test("dofile with Windows backslashes resolves a bundled helper by basename")
    func dofileBackslashResolves() async throws {
        let lua = try await shimmed()
        // Build a backslash path (as MUSHclient plugins do) without escape
        // ambiguity, pointing at the bundled aardwolf_colors helper.
        let effects = try await lua.run("""
        local bs = string.char(92)
        local path = "x" .. bs .. "y" .. bs .. "aardwolf_colors.lua"
        proteles.echo(tostring(pcall(dofile, path)))
        """)
        #expect(effects == [.echo("true")])
    }

    @Test("sandboxed io.lines reads a file inside the sandbox; outside is denied")
    func sandboxedIO() async throws {
        let lua = try await shimmed()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "alpha\nbeta".write(to: dir.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
        await lua.setSQLiteDirectory(dir.path)

        let inside = try await lua.run("""
        for line in io.lines("\(dir.path)/list.txt") do proteles.echo(line) end
        """)
        #expect(inside == [.echo("alpha"), .echo("beta")])

        // A path outside the sandbox root can't be opened.
        let outside = try await lua.run("""
        proteles.echo(tostring(io.open("/etc/hosts", "r") == nil))
        """)
        #expect(outside == [.echo("true")])
    }

    @Test("ImportXML parses a fragment and dispatches to AddTriggerEx/AddAlias")
    func importXMLRegisters() async throws {
        let lua = try await shimmed()
        // ImportXML resolves AddTriggerEx/AddAlias as globals at call time, so we
        // capture them to observe what the fragment parser dispatched (without a
        // live engine). Two triggers (one regexp) + one alias here.
        let effects = try await lua.run("""
        local captured = {}
        function AddTriggerEx(name, match, response, flags)
          captured[#captured + 1] = name .. "|" .. match .. "|" .. tostring(flags > 0)
        end
        function AddAlias(name, match)
          captured[#captured + 1] = "alias:" .. name .. "|" .. match
        end
        local frag = "<triggers>"
          .. '<trigger name="hi" match="^hello$" enabled="y" regexp="y"></trigger>'
          .. '<trigger name="bye" match="^bye$" enabled="y"></trigger>'
          .. "</triggers>"
          .. '<aliases><alias name="a1" match="^xx$" enabled="y"></alias></aliases>'
        proteles.echo(tostring(ImportXML(frag)))
        proteles.echo(captured[1]); proteles.echo(captured[2]); proteles.echo(captured[3])
        proteles.echo(tostring(ImportXML(42)))
        """)
        // 3 installed; trigger flags > 0 (enabled+regexp); non-string arg → -1.
        #expect(effects == [
            .echo("3"),
            .echo("hi|^hello$|true"),
            .echo("bye|^bye$|true"),
            .echo("alias:a1|^xx$"),
            .echo("-1")
        ])
    }

    @Test("rex shim: named + numbered captures, no-match, invalid-pattern (D2)")
    func rexShim() async throws {
        let lua = try await shimmed()
        // [0-9]/[A-Za-z] avoid backslash-escaping noise; named captures use PCRE
        // (?P<>) which PatternMatcher bridges to ICU.
        let effects = try await lua.run("""
        local rex = require "rex"
        local re = rex.new("Level (?P<level>[0-9]+), tier (?P<tier>[0-9]+)")
        local s = re:match("Level 60, tier 6 here")
        local _, _, t = re:match("Level 60, tier 6 here")
        proteles.echo("matched:" .. tostring(s ~= nil))
        proteles.echo("named:" .. tostring(t.level) .. "/" .. tostring(t.tier))
        local _, _, t2 = rex.new("revenge on ([A-Za-z]+) for"):match("revenge on Goblin for 15")
        proteles.echo("g1:" .. tostring(t2[1]))
        proteles.echo("nomatch:" .. tostring(re:match("nope") == nil))
        proteles.echo("invalid:" .. tostring(pcall(rex.new, "(")))
        """)
        #expect(effects.contains(.echo("matched:true")))
        #expect(effects.contains(.echo("named:60/6"))) // PCRE named captures
        #expect(effects.contains(.echo("g1:Goblin"))) // numbered capture (1-based)
        #expect(effects.contains(.echo("nomatch:true")))
        #expect(effects.contains(.echo("invalid:false"))) // bad pattern → rex.new raises
    }

    @Test("OpenBrowser: web schemes emit an effect with plugin identity; others rejected (D8)")
    func openBrowser() async throws {
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.ob" name="OB Plugin"/>
        <script><![CDATA[
        function OnPluginInstall()
          proteles.send("http:" .. tostring(OpenBrowser("http://x.com") == error_code.eOK))
          proteles.send("https:" .. tostring(OpenBrowser("https://aardwolf.com/x") == error_code.eOK))
          proteles.send("mail:" .. tostring(OpenBrowser("mailto:a@b.com") == error_code.eOK))
          proteles.send("file:" .. tostring(OpenBrowser("file:///etc/passwd") == error_code.eBadParameter))
          proteles.send("js:" .. tostring(OpenBrowser("javascript:alert(1)") == error_code.eBadParameter))
        end
        ]]></script></muclient>
        """)
        let effects = try await engine.loadPlugin(plugin)
        // Return codes: web schemes eOK, others eBadParameter.
        for tag in ["http:true", "https:true", "mail:true", "file:true", "js:true"] {
            #expect(effects.contains(.send(tag)))
        }
        // Web schemes carry the calling plugin's id + name for the app's prompt.
        #expect(effects.contains(.openBrowser(
            url: "https://aardwolf.com/x", pluginID: "com.ob", pluginName: "OB Plugin"
        )))
        #expect(effects.contains(.openBrowser(
            url: "mailto:a@b.com", pluginID: "com.ob", pluginName: "OB Plugin"
        )))
        // Rejected schemes emit NO effect (can't launch arbitrary handlers).
        #expect(!effects.contains { effect in
            if case .openBrowser(let url, _, _) = effect {
                return url.hasPrefix("file:") || url.hasPrefix("javascript:")
            }
            return false
        })
    }

    @Test("DeleteAlias removes an alias; NoteStyle/EnableAliasGroup are present")
    func aliasDeleteAndGroupGlobals() async throws {
        let lua = try await shimmed()
        // AddAlias tracks __aliasNames → IsAlias eOK; DeleteAlias clears it →
        // IsAlias not-found (the gap several cleanup-loop plugins hit).
        let effects = try await lua.run("""
        AddAlias("a1", "^x$", "", 0, "")
        proteles.echo(tostring(IsAlias("a1") == error_code.eOK))
        proteles.echo(tostring(DeleteAlias("a1") == error_code.eOK))
        proteles.echo(tostring(IsAlias("a1") == error_code.eAliasNotFound))
        proteles.echo(tostring(NoteStyle(5) == error_code.eOK))
        proteles.echo(tostring(EnableAliasGroup("g", true) == error_code.eOK))
        """)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == ["true", "true", "true", "true", "true"])
        // DeleteAlias routed to the host removeAlias effect; EnableAliasGroup → enableGroup.
        #expect(effects.contains(.removeAlias("a1")))
        #expect(effects.contains(.enableGroup(name: "g", on: true)))
    }
}
