import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — MUSHclient compat shim")
struct CompatShimTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("Send / SendNoEcho / Execute map to the right effects")
    func sending() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("Send('kill mob'); SendNoEcho('secret'); Execute('north')")
        #expect(effects == [.send("kill mob"), .sendNoEcho("secret"), .execute("north")])
    }

    @Test("CallPlugin to the mapper id records a mapperCall effect")
    func callPluginMapper() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("CallPlugin('b6eae87ccedd84f510b74714', 'find', '3', '9')")
        #expect(effects == [.mapperCall(function: "find", args: ["3", "9"])])
    }

    @Test("CallPlugin to another id forwards to exports (no mapperCall)")
    func callPluginOther() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("CallPlugin('some_other_plugin', 'whatever')")
        #expect(!effects.contains { if case .mapperCall = $0 { true } else { false } })
    }

    @Test("Note echoes; ColourNote emits a single styled segment")
    func output() async throws {
        let lua = try await shimmed()
        let note = try await lua.run("Note('hello')")
        #expect(note == [.echo("hello")])

        let coloured = try await lua.run("ColourNote('red', '', 'danger')")
        #expect(coloured == [.colourNote([
            NoteSegment(text: "danger", foreground: "red", background: nil)
        ])])
    }

    @Test("ColourNote preserves per-segment colours (one run per triple)")
    func colourNoteMultiTriplet() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("ColourNote('white', '', 'a', 'red', 'blue', 'b')")
        #expect(effects == [.colourNote([
            NoteSegment(text: "a", foreground: "white", background: nil),
            NoteSegment(text: "b", foreground: "red", background: "blue")
        ])])
    }

    @Test("SetVariable / GetVariable round-trip and return eOK")
    func variables() async throws {
        let lua = try await shimmed()
        #expect(try await lua.number("SetVariable('hp', 100)") == 0) // eOK
        #expect(try await lua.string("GetVariable('hp')") == "100") // coerced to string
        let effects = try await lua.run("Send(GetVariable('hp'))")
        #expect(effects == [.send("100")])
    }

    @Test("GetInfo and GetPluginID proxy the plugin context")
    func introspection() async throws {
        let lua = try await shimmed()
        await lua.setPluginContext(PluginContext(
            pluginID: "com.x.y", pluginName: "Y", appDirectory: "/app"
        ))
        #expect(try await lua.string("GetInfo(66)") == "/app")
        #expect(try await lua.string("GetPluginID()") == "com.x.y")
    }

    @Test("GetPluginVariable reads another plugin's scope")
    func crossPluginVariable() async throws {
        let lua = try await shimmed()
        await lua.setVariableScope("com.other")
        try await lua.run("SetVariable('shared', 'value')")
        await lua.setVariableScope("_user")
        #expect(try await lua.string("GetPluginVariable('com.other', 'shared')") == "value")
    }

    @Test("Trim strips surrounding whitespace; error_code.eOK is 0")
    func helpers() async throws {
        let lua = try await shimmed()
        #expect(try await lua.string("Trim('  hi  ')") == "hi")
        #expect(try await lua.number("error_code.eOK") == 0)
    }

    @Test("GetAlphaOption returns a blank string; SetAlphaOption returns eOK")
    func alphaOptions() async throws {
        let lua = try await shimmed()
        // Plugins (e.g. autobypass on reload) read/write string options; the
        // stubs must not error — unset reads are "" and writes are eOK.
        #expect(try await lua.string("GetAlphaOption('anything')").isEmpty)
        #expect(try await lua.number("SetAlphaOption('k', 'v')") == 0)
    }

    @Test("AddAlias/EnableAlias map to the right effects; alias_flag values match")
    func aliasRegistration() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        AddAlias("a1", "^sleep$", "", alias_flag.Enabled + alias_flag.RegularExpression, "fn")
        EnableAlias("a1", false)
        """)
        #expect(effects == [
            .addAlias(name: "a1", pattern: "^sleep$", flags: 1 + 128, script: "fn"),
            .enableAlias(name: "a1", on: false)
        ])
    }

    @Test("GetEchoInput / clipboard stubs don't error")
    func echoAndClipboard() async throws {
        let lua = try await shimmed()
        #expect(try await lua.number("GetEchoInput()") == 1)
        #expect(try await lua.string("GetClipboard()").isEmpty)
        #expect(try await lua.number("SetClipboard('x')") == 0)
    }

    @Test("stylesToANSI(ColoursToStyles(s)) round-trips coloured text")
    func stylesRoundTrip() async throws {
        let lua = try await shimmed()
        // dinv's dbot.print idiom: AnsiNote(stylesToANSI(ColoursToStyles(s))).
        // aardwolf_colors is dofile'd into globals (as dinv does it).
        let ansi = try await lua.string("""
        (function()
          dofile("aardwolf_colors.lua")
          return stylesToANSI(ColoursToStyles("@Rred text@w"))
        end)()
        """)
        #expect(ansi.contains("red text"))
        #expect(ansi.unicodeScalars.contains("\u{1B}"))
    }

    @Test("Send_GMCP_Packet produces a sendGMCP effect")
    func sendGMCPPacket() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("Send_GMCP_Packet('request prompt')")
        #expect(effects == [.sendGMCP("request prompt")])
    }

    @Test("print joins its arguments with tabs and echoes")
    func printEchoes() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("print('a', 'b', 1)")
        #expect(effects == [.echo("a\tb\t1")])
    }

    @Test("IsConnected reflects the host-set connection state")
    func isConnectedReflectsHost() async throws {
        let lua = try await shimmed()
        #expect(try await lua.boolean("IsConnected() == false"))
        await lua.setConnected(true)
        #expect(try await lua.boolean("IsConnected() == true"))
    }

    @Test("GetPluginInfo(id, 20) returns the plugin directory")
    func getPluginInfoDirectory() async throws {
        let lua = try await shimmed()
        await lua.setPluginContext(PluginContext(
            pluginID: "p", pluginName: "P", pluginDirectory: "/plugins/p"
        ))
        #expect(try await lua.string("GetPluginInfo(GetPluginID(), 20)") == "/plugins/p")
    }
}
