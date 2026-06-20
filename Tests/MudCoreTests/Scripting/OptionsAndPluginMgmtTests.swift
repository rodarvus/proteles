import Foundation
@testable import MudCore
import Testing

/// The world-Options family (`GetOption`/`SetOption`/`GetAlphaOption`/
/// `GetGlobalOption` + the `*OptionList` calls) and plugin-management functions
/// (`GetPluginList`/`PluginSupports`/`UnloadPlugin`/`Connect`/`LoadPlugin`) added
/// to the generic shim from the gap audit. Options are a faithful MUSHclient
/// default table + shim-local write-through; plugin mgmt routes to host queries
/// (list/supports) and control effects (unload/connect).
@Suite("Generic shim — Options family + plugin management (gap)")
struct OptionsAndPluginMgmtTests {
    private func echoes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
    }

    // MARK: - Options family

    @Test("GetOption/SetOption/GetAlphaOption/GetGlobalOption + lists")
    func optionsFamily() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("""
        proteles.echo("triggers=" .. tostring(GetOption("enable_triggers")))   -- 1
        proteles.echo("utf8=" .. tostring(GetOption("utf_8")))                  -- 1 (Proteles truth)
        proteles.echo("stack=" .. tostring(GetOption("enable_command_stack")))  -- 1 (Proteles truth)
        proteles.echo("bold=" .. tostring(GetOption("show_bold")))              -- 0 (MUSHclient default)
        proteles.echo("unknown=" .. tostring(GetOption("nope")))                -- -1
        proteles.echo("set=" .. tostring(SetOption("auto_pause", 0)))           -- eOK (0)
        proteles.echo("ap=" .. tostring(GetOption("auto_pause")))               -- 0 (round-trip)
        proteles.echo("setbad=" .. tostring(SetOption("nope", 1) == error_code.eUnknownOption))
        proteles.echo("csc=" .. tostring(GetAlphaOption("command_stack_character")))  -- ;
        proteles.echo("prefix=[" .. tostring(GetAlphaOption("script_prefix")) .. "]") -- []
        proteles.echo("font=" .. tostring(GetAlphaOption("output_font_name")))        -- FixedSys (unset)
        proteles.echo("aunknown=[" .. tostring(GetAlphaOption("nope")) .. "]")        -- [] (lenient)
        proteles.echo("smooth=" .. tostring(GetGlobalOption("SmoothScrolling")))      -- 0 (case-insensitive)
        proteles.echo("gunknown=" .. tostring(GetGlobalOption("nope")))               -- nil
        proteles.echo("nlist=" .. tostring(#GetOptionList() > 0))                     -- true
        proteles.echo("alist=" .. tostring(#GetAlphaOptionList()))                    -- 3
        """)
        #expect(echoes(effects) == [
            "triggers=1", "utf8=1", "stack=1", "bold=0", "unknown=-1",
            "set=0", "ap=0", "setbad=true",
            "csc=;", "prefix=[]", "font=FixedSys", "aunknown=[]",
            "smooth=0", "gunknown=nil", "nlist=true", "alist=3"
        ])
    }

    @Test("GetAlphaOption(output_font_name) reports the configured font (host-pushed)")
    func outputFontNameIsLive() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        await lua.setOutputFontName("JetBrains Mono NL")
        let effects = try await lua.run("""
        proteles.echo("font=" .. GetAlphaOption("output_font_name"))
        """)
        #expect(echoes(effects) == ["font=JetBrains Mono NL"])
    }

    @Test("SetAlphaOption round-trips through GetAlphaOption")
    func setAlphaOptionRoundTrip() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("""
        proteles.echo("before=[" .. GetAlphaOption("script_prefix") .. "]")
        SetAlphaOption("script_prefix", "//")
        proteles.echo("after=[" .. GetAlphaOption("script_prefix") .. "]")
        """)
        #expect(echoes(effects) == ["before=[]", "after=[//]"])
    }

    // MARK: - Plugin management — control effects

    @Test("Connect emits .connect when closed; UnloadPlugin + LoadPlugin behave")
    func pluginControlEffects() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("""
        proteles.echo("conn=" .. tostring(Connect()))            -- not connected -> eOK
        proteles.echo("unload=" .. tostring(UnloadPlugin("abc123def456")))
        proteles.echo("load=" .. tostring(LoadPlugin("/tmp/x.xml")))
        """)
        #expect(echoes(effects) == ["conn=0", "unload=0", "load=0"])
        #expect(effects.contains(.connect))
        #expect(effects.contains(.unloadPlugin(id: "abc123def456")))
        // LoadPlugin is a logged no-op (transcript trace), not a real load.
        let loggedLoad = effects.contains { effect in
            if case .trace(let text) = effect { text.contains("LoadPlugin") } else { false }
        }
        #expect(loggedLoad)
    }

    @Test("Connect returns eWorldOpen when already connected (no effect)")
    func connectWhenOpen() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        await lua.setConnected(true)
        let effects = try await lua.run("""
        proteles.echo("conn=" .. tostring(Connect() == error_code.eWorldOpen))
        """)
        #expect(echoes(effects) == ["conn=true"])
        #expect(!effects.contains(.connect))
    }

    // MARK: - Plugin management — host queries (end to end)

    @Test("GetPluginList includes the loaded plugin; PluginSupports detects its routines")
    func pluginListAndSupports() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: pluginMgmtPlugin))

        let effects = await engine.process(line: "probe").effects
        #expect(effects.contains(.send("self=true"))) // GetPluginList contains own id
        #expect(effects.contains(.send("has=0"))) // PluginSupports(self, "MyRoutine") == eOK
        #expect(effects.contains(.send("hasnot=30036"))) // == eNoSuchRoutine
    }

    private let pluginMgmtPlugin = """
    <muclient>
    <plugin id="com.test.pmgmt" name="PMgmt"/>
    <triggers>
      <trigger name="probe" enabled="y" regexp="y" match="^probe$" send_to="12"><send>
        local found = false
        for _, id in ipairs(GetPluginList()) do if id == GetPluginID() then found = true end end
        Send("self=" .. tostring(found))
        Send("has=" .. tostring(PluginSupports(GetPluginID(), "MyRoutine")))
        Send("hasnot=" .. tostring(PluginSupports(GetPluginID(), "Nope")))
      </send></trigger>
    </triggers>
    <script><![CDATA[
    function MyRoutine() end
    ]]></script>
    </muclient>
    """
}
