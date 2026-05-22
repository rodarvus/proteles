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

    @Test("Note echoes; ColourNote applies the first triplet's colours")
    func output() async throws {
        let lua = try await shimmed()
        let note = try await lua.run("Note('hello')")
        #expect(note == [.echo("hello")])

        let coloured = try await lua.run("ColourNote('red', '', 'danger')")
        #expect(coloured == [.note(text: "danger", foreground: "red", background: nil)])
    }

    @Test("ColourNote concatenates multi-triplet segment text")
    func colourNoteMultiTriplet() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("ColourNote('white', '', 'a', 'red', '', 'b')")
        #expect(effects == [.note(text: "ab", foreground: "white", background: nil)])
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
}
