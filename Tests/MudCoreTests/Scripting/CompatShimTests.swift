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

    @Test("CallPlugin storeFromOutside to the chat-capture id bridges to native chat")
    func callPluginChatCapture() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run(
            "CallPlugin('b555825a4a5700c35fa80780', 'storeFromOutside', '@Ghi there@w', 'RP')"
        )
        #expect(effects == [.chatCapture(text: "@Ghi there@w", channel: "RP")])
    }

    @Test("storeFromOutside without a tab still bridges (empty channel)")
    func callPluginChatCaptureNoTab() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run(
            "CallPlugin('b555825a4a5700c35fa80780', 'storeFromOutside', 'plain text')"
        )
        #expect(effects == [.chatCapture(text: "plain text", channel: "")])
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

    @Test("ColourTell cells carry their colour into the flushed line (leveldb rows)")
    func colourTellCarriesColour() async throws {
        let lua = try await shimmed()
        // leveldb builds a row as coloured cells via ColourTell, flushed by a
        // ColourNote/Note — every cell's colour must survive (the bug: ColourTell
        // used to buffer only text, so rows rendered in the default colour).
        let effects = try await lua.run("""
        ColourTell('#87CEEB', '', 'mob')
        ColourNote('cyan', '', '  42')
        """)
        #expect(effects == [.colourNote([
            NoteSegment(text: "mob", foreground: "#87CEEB", background: nil),
            NoteSegment(text: "  42", foreground: "cyan", background: nil)
        ])])
    }

    @Test("A plain Tell prefix flushes onto the Note line")
    func tellPrefixFlushes() async throws {
        let lua = try await shimmed()
        // Tell (no colour) + ColourNote → the prefix leads as a default segment.
        let effects = try await lua.run("Tell('[tag] '); ColourNote('red', '', 'msg')")
        #expect(effects == [.colourNote([
            NoteSegment(text: "[tag] ", foreground: nil, background: nil),
            NoteSegment(text: "msg", foreground: "red", background: nil)
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

    @Test("Notify raises a .notify effect (the phase-2 scripting hook, #14)")
    func notifyEffect() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("Notify('Quest done', 'return to the questor')")
        #expect(effects == [.notify(title: "Quest done", body: "return to the questor")])
        // Body is optional.
        let titleOnly = try await lua.run("Notify('Heads up')")
        #expect(titleOnly == [.notify(title: "Heads up", body: "")])
    }

    @Test("Button.* records button-bar effects (the #15 scripting API)")
    func buttonScriptingAPI() async throws {
        let lua = try await shimmed()
        #expect(try await lua.run("Button.add('Combat', 'Heal', 'quaff heal')")
            == [.button(.add(group: "Combat", label: "Heal", command: "quaff heal"))])
        #expect(try await lua.run("Button.toggle('Combat', 'Wimpy', 'wimpy 200', 'wimpy 0')")
            == [.button(.toggle(group: "Combat", label: "Wimpy", on: "wimpy 200", off: "wimpy 0"))])
        #expect(try await lua.run("Button.state('Wimpy', true)")
            == [.button(.setState(label: "Wimpy", on: true))])
        #expect(try await lua.run("Button.remove('Heal')")
            == [.button(.remove(label: "Heal"))])
    }

    @Test("addxml.trigger maps an attribute table to AddTriggerEx flags + body")
    func addxmlTrigger() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        require "addxml"
        addxml.trigger { name = "gag1", match = "^junk$", regexp = true,
          omit_from_output = true, enabled = true, sequence = 50,
          send_to = 12, send = "gagged = gagged + 1" }
        """)
        // Enabled(1) + RegularExpression(32) + OmitFromOutput(4) = 37; send_to=12
        // (script) runs the `send` text as Lua, so it's the trigger body.
        #expect(effects == [
            .addTrigger(
                name: "gag1",
                pattern: "^junk$",
                flags: 37,
                script: "gagged = gagged + 1",
                sequence: 50
            )
        ])
    }

    // #29: SetTriggerOption was a no-op, so a plugin retuning a trigger at
    // runtime silently had no effect. Now `enabled`/`group` route to their
    // engine ops and the rest go to a host op that mutates the named trigger.
    @Test("SetTriggerOption routes enabled + group to the host engines")
    func setTriggerOptionEnabledGroup() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("AddTriggerEx('t', '^x$', '', 1, -1, 0, '', 'fn', 12, 100)")
        // enabled "0" (MUSHclient passes a string) → disable; group → move group.
        let effects = try await lua.run(
            "SetTriggerOption('t','enabled','0'); SetTriggerOption('t','group','grp')"
        )
        #expect(effects == [
            .enableTrigger(name: "t", on: false),
            .setTriggerGroup(name: "t", group: "grp")
        ])
    }

    @Test("SetTriggerOption routes other options (sequence/match/flags) to the engine by name")
    func setTriggerOptionToEngine() async throws {
        let lua = try await shimmed()
        _ = try await lua.run("AddTriggerEx('t', '^x$', '', 1, -1, 0, '', 'fn', 12, 100)")
        // omit_from_output / sequence / match → one host op that mutates the
        // named trigger on the engine (works for XML-defined triggers too).
        let effects = try await lua.run("""
        SetTriggerOption('t','omit_from_output','y')
        SetTriggerOption('t','sequence',40)
        SetTriggerOption('t','match','^y$')
        """)
        #expect(effects == [
            .setTriggerOption(name: "t", option: "omit_from_output", value: "y"),
            .setTriggerOption(name: "t", option: "sequence", value: "40"),
            .setTriggerOption(name: "t", option: "match", value: "^y$")
        ])
    }

    @Test("DeleteTemporaryTriggers removes only Temporary-flagged triggers")
    func deleteTemporaryTriggers() async throws {
        let lua = try await shimmed()
        // t1 Temporary(16384)+Enabled(1); t2 Enabled(1) only.
        _ = try await lua.run("AddTriggerEx('t1','^a$','',16385,-1,0,'','fn',12,100)")
        _ = try await lua.run("AddTriggerEx('t2','^b$','',1,-1,0,'','fn',12,100)")
        let removed = try await lua.run("n = DeleteTemporaryTriggers()")
        #expect(removed == [.removeTrigger("t1")]) // only the temporary one
        #expect(try await lua.number("n") == 1)
        #expect(try await lua.number("IsTrigger('t1')") == 30005) // gone
        #expect(try await lua.number("IsTrigger('t2')") == 0) // kept
    }

    @Test("addxml.alias maps to AddAlias; MUSHclient y/n booleans accepted")
    func addxmlAlias() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        require "addxml"
        addxml.alias { name = "a1", match = "^go$", regexp = "y", script = "fn" }
        """)
        // Enabled(1) + RegularExpression(128) = 129.
        #expect(effects == [.addAlias(name: "a1", pattern: "^go$", flags: 129, script: "fn")])
    }

    @Test("addxml is require-able and returns the module table")
    func addxmlRequire() async throws {
        let lua = try await shimmed()
        #expect(try await lua.number("type(require('addxml').trigger) == 'function' and 1 or 0") == 1)
    }

    @Test("IsTrigger/IsTimer/IsAlias report existence via eOK / not-found codes")
    func existenceChecks() async throws {
        let lua = try await shimmed()
        // Unknown names → type-specific not-found codes (dinv's de-init relies
        // on this to no-op deleting objects it never instantiated).
        #expect(try await lua.number("IsTrigger('nope')") == 30005) // eTriggerNotFound
        #expect(try await lua.number("IsTimer('nope')") == 30017) // eTimerNotFound
        #expect(try await lua.number("IsAlias('nope')") == 30013) // eAliasNotFound
        // After registering, the name resolves to eOK; DeleteTrigger clears it.
        _ = try await lua.run("AddTriggerEx('t1', '^x$', '', 0, -1, 0, '', 'fn', 12, 0)")
        #expect(try await lua.number("IsTrigger('t1')") == 0)
        _ = try await lua.run("DeleteTrigger('t1')")
        #expect(try await lua.number("IsTrigger('t1')") == 30005)
        _ = try await lua.run("AddAlias('a1', '^y$', '', 1, 'fn')")
        #expect(try await lua.number("IsAlias('a1')") == 0)
        _ = try await lua.run("AddTimer('m1', 0, 0, 5, '', 0, 'fn'); DeleteTimer('m1')")
        #expect(try await lua.number("IsTimer('m1')") == 30017)
    }

    @Test("GetEchoInput / clipboard degrade safely with no provider")
    func echoAndClipboard() async throws {
        let lua = try await shimmed()
        #expect(try await lua.number("GetEchoInput()") == 1)
        // No provider injected (headless): reads "" and writes are accepted.
        #expect(try await lua.string("GetClipboard()").isEmpty)
        #expect(try await lua.number("SetClipboard('x')") == 0)
    }

    // #30: GetClipboard/SetClipboard route through the app-injected provider
    // (NSPasteboard on macOS), not the old "" / discard stubs.
    @Test("GetClipboard/SetClipboard round-trip through an injected provider")
    func clipboardProviderRoundTrip() async throws {
        let lua = try await shimmed()
        let box = ClipboardBox()
        await lua.setClipboardProvider(ClipboardProvider(get: { box.value }, set: { box.value = $0 }))
        #expect(try await lua.number("SetClipboard('hello')") == 0)
        #expect(box.value == "hello") // write reached the provider
        #expect(try await lua.string("GetClipboard()") == "hello") // read came back
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

    @Test("Execute runs script-prefixed text as Lua, plain text as a command")
    func executeScriptPrefix() async throws {
        let lua = try await shimmed()
        // A run of leading backslashes (the MUSHclient script prefix) → eval.
        let scripted = try await lua.run(#"Execute(string.char(92, 92, 92) .. 'Send("hi")')"#)
        #expect(scripted == [.send("hi")])
        // No prefix → an ordinary world command.
        let plain = try await lua.run("Execute('north')")
        #expect(plain == [.execute("north")])
    }

    @Test("DoAfter / DoAfterSpecial map to scheduleAfter (script vs send)")
    func deferredActions() async throws {
        let lua = try await shimmed()
        let send = try await lua.run("DoAfter(1.5, 'kill mob')")
        #expect(send == [.scheduleAfter(seconds: 1.5, isScript: false, body: "kill mob")])
        // sendto.script (12) → run the body as Lua.
        let script = try await lua.run("DoAfterSpecial(2, 'foo()', sendto.script)")
        #expect(script == [.scheduleAfter(seconds: 2, isScript: true, body: "foo()")])
    }

    @Test("ReloadPlugin records a reloadPlugin effect for the given id")
    func reloadPlugin() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("ReloadPlugin('com.test.thing')")
        #expect(effects == [.reloadPlugin(id: "com.test.thing")])
    }

    @Test("SetEchoInput round-trips through GetEchoInput")
    func echoInputRoundTrip() async throws {
        let lua = try await shimmed()
        #expect(try await lua.boolean("GetEchoInput() == 1"))
        _ = try await lua.run("SetEchoInput(false)")
        #expect(try await lua.boolean("GetEchoInput() == 0"))
        _ = try await lua.run("SetEchoInput(true)")
        #expect(try await lua.boolean("GetEchoInput() == 1"))
    }
}

/// A thread-safe string box for the clipboard-provider round-trip test (the
/// provider closures are invoked synchronously on the script executor thread).
private final class ClipboardBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
