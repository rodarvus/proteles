@testable import MudCore
import Testing

/// Each plugin's `GetVariable`/`SetVariable` must operate on **its own** scope,
/// even from lifecycle callbacks (`OnPluginInstall`/`OnPluginSaveState`) and
/// owned triggers — regardless of which plugin loaded last. Regression for the
/// bug where `currentVariableScope` was process-global and set only at load
/// time, so a plugin loaded mid-session (e.g. dinv, armed) "stole" the scope and
/// another plugin's saved state (e.g. leveldb's `enabled` flag from `ldb on`)
/// landed in the wrong bucket — and was lost on the next launch.
@Suite("Plugin variable scoping")
struct PluginVariableScopeTests {
    /// A plugin that persists its own id under "flag" on save, and echoes the
    /// value it reads back on install (so a reload round-trip is observable).
    private func plugin(id: String) throws -> MUSHclientPlugin {
        try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="\(id)" name="\(id)"/>
        <script><![CDATA[
        function OnPluginInstall()
          proteles.send("install:" .. tostring(GetVariable("flag")))
        end
        function OnPluginSaveState()
          SetVariable("flag", GetPluginID())
        end
        ]]></script>
        </muclient>
        """)
    }

    @Test("OnPluginSaveState writes each plugin's variable into its own scope")
    func saveStateScopedPerPlugin() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(plugin(id: "com.a"))
        _ = try await engine.loadPlugin(plugin(id: "com.b")) // loaded last

        // Disconnect fires OnPluginSaveState on every plugin (A then B).
        _ = await engine.disconnectPlugins()
        let snapshot = await engine.variablesSnapshot()

        // Each plugin's flag must live in ITS scope — not all in the last one's.
        #expect(snapshot["com.a"]?["flag"] == "com.a")
        #expect(snapshot["com.b"]?["flag"] == "com.b")
    }

    @Test("SaveState() runs the calling plugin's OnPluginSaveState callback")
    func explicitSaveStateUsesCallingPluginEnvironment() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(plugin(id: "com.test.explicit-save"))

        let effects = await engine.runInPluginEnvironment(
            "com.test.explicit-save",
            """
            SaveState()
            proteles.send("saved:" .. tostring(GetVariable("flag")))
            """
        )

        #expect(effects == [.send("saved:com.test.explicit-save")])
    }

    @Test("a plugin-set global is readable via _G.x, and shim globals still resolve")
    func globalReadableViaUnderscoreG() async throws {
        // Regression: a global the plugin sets in its <script> must be visible as
        // `_G.x` (MUSHclient gives each plugin its own global namespace). Without
        // `env._G = env`, `_G.plugin_short_name` resolved against the shared real
        // globals and came back nil — so a plugin reading its own short-name
        // global got nil and fell back to its full plugin name.
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.gtest" name="Global_Test"/>
        <script><![CDATA[
        plugin_short_name = "PX"
        function OnPluginInstall()
          proteles.send("tag:" .. tostring(_G.plugin_short_name))
          proteles.send("shimfn:" .. type(_G.GetPluginID))
        end
        ]]></script>
        </muclient>
        """)
        let effects = try await engine.loadPlugin(plugin)
        #expect(effects.contains(.send("tag:PX"))) // plugin global via _G
        #expect(effects.contains(.send("shimfn:function"))) // inherited shim global via _G
    }

    @Test("AddAlias(regex) fires on input; EnableAliasGroup + DeleteAlias control it")
    func aliasGroupAndDeleteFunctional() async throws {
        // End-to-end check mirroring the Proteles_AliasGroup_Test mock: control
        // aliases (fired via input, so their effects are consumed into the engine)
        // arm a runtime regex alias, toggle its group, and delete it. The runtime
        // alias REQUIRES alias_flag.RegularExpression — without it `^aggrp$` is a
        // literal/wildcard that never matches "aggrp".
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.ag" name="AG"/>
        <aliases>
          <alias match="^ag arm$" enabled="y" regexp="y" send_to="12"><send>ag_arm()</send></alias>
          <alias match="^ag off$" enabled="y" regexp="y" send_to="12"><send>ag_off()</send></alias>
          <alias match="^ag on$"  enabled="y" regexp="y" send_to="12"><send>ag_on()</send></alias>
          <alias match="^ag del$" enabled="y" regexp="y" send_to="12"><send>ag_del()</send></alias>
        </aliases>
        <script><![CDATA[
        function g_fire() proteles.send("grp-fired") end
        function ag_off() EnableAliasGroup("agtg", false) end
        function ag_on() EnableAliasGroup("agtg", true) end
        function ag_del() DeleteAlias("aggrp") end
        function ag_arm()
          AddAlias("aggrp", "^aggrp$", "", alias_flag.Enabled + alias_flag.RegularExpression, "g_fire")
          SetAliasOption("aggrp", "group", "agtg")
        end
        ]]></script></muclient>
        """)
        _ = try await engine.loadPlugin(plugin)
        _ = await engine.expandInput("ag arm")
        #expect(await engine.expandInput("aggrp").contains(.send("grp-fired"))) // fires
        _ = await engine.expandInput("ag off")
        #expect(await !engine.expandInput("aggrp").contains(.send("grp-fired"))) // group disabled
        _ = await engine.expandInput("ag on")
        #expect(await engine.expandInput("aggrp").contains(.send("grp-fired"))) // re-enabled
        _ = await engine.expandInput("ag del")
        #expect(await !engine.expandInput("aggrp").contains(.send("grp-fired"))) // deleted
    }

    @Test("a bundled module's bare global (movewindow) is usable after require")
    func bundledModuleGlobalReachesPlugin() async throws {
        // Regression: plugins `require "movewindow"` and discard the return, then
        // call the BARE GLOBAL `movewindow.install(...)` (e.g. Aard_Affects). The
        // bundled stub must define `movewindow` as a global (like the real lib +
        // gmcphelper), not just return a local table — else the bare use hits
        // "attempt to index global 'movewindow' (a nil value)".
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.mw" name="MW_Test"/>
        <script><![CDATA[
        require "movewindow"
        function OnPluginInstall()
          local info = movewindow.install(0, 6, 2, true)
          proteles.send("mw:" .. type(movewindow) .. ":" .. type(info))
        end
        ]]></script>
        </muclient>
        """)
        let effects = try await engine.loadPlugin(plugin)
        #expect(effects.contains(.send("mw:table:table")))
    }

    @Test("group-delete removes the plugin's grouped triggers + aliases (D4)")
    func groupDelete() async throws {
        // Drives the same idiom as the Aard plugins: arm a grouped (addxml) gag
        // trigger + a grouped runtime alias, then DeleteTriggerGroup/
        // DeleteAliasGroup via the consumed alias path. Also pins that addxml now
        // honours `group`. Control aliases are fired via expandInput so their
        // effects are applied to the engine.
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.gd" name="GD"/>
        <aliases>
          <alias match="^gd arm$" enabled="y" regexp="y" send_to="12"><send>gd_arm()</send></alias>
          <alias match="^gd dt$" enabled="y" regexp="y" send_to="12"><send>gd_dt()</send></alias>
          <alias match="^gd da$" enabled="y" regexp="y" send_to="12"><send>gd_da()</send></alias>
        </aliases>
        <script><![CDATA[
        require "addxml"
        function af() proteles.send("alias-fired") end
        function gd_dt() DeleteTriggerGroup("gg") end
        function gd_da() DeleteAliasGroup("gg") end
        function gd_arm()
          addxml.trigger { match = "TLINE", regexp = false, omit_from_output = true,
            enabled = true, group = "gg" }
          AddAlias("ga1", "^aax$", "", alias_flag.Enabled + alias_flag.RegularExpression, "af")
          SetAliasOption("ga1", "group", "gg")
        end
        ]]></script></muclient>
        """)
        _ = try await engine.loadPlugin(plugin)
        _ = await engine.expandInput("gd arm")
        #expect(await engine.process(line: "TLINE").gag) // grouped gag trigger active
        #expect(await engine.expandInput("aax").contains(.send("alias-fired"))) // grouped alias active
        _ = await engine.expandInput("gd dt")
        #expect(await !engine.process(line: "TLINE").gag) // trigger group deleted
        _ = await engine.expandInput("gd da")
        #expect(await !engine.expandInput("aax").contains(.send("alias-fired"))) // alias group deleted
    }

    @Test("DeleteTemporaryTriggers only removes the calling plugin's own triggers")
    func deleteTemporaryTriggersScopedPerPlugin() async throws {
        // Plugin A arms a TEMPORARY gag trigger; plugin B then calls
        // DeleteTemporaryTriggers. The shim tracking tables are shared across
        // plugins, so an unscoped bulk-clear would delete A's trigger from B's
        // call. Owner-scoping keeps A's intact (still gags its line). Regression
        // for the same class of bug as ResetTimers stealing dinv's wish timer.
        let engine = try ScriptEngine()
        let pluginA = """
        <muclient>
        <plugin id="com.a" name="A"/>
        <script><![CDATA[
        require "addxml"
        function OnPluginInstall()
          addxml.trigger { match = "AAA", regexp = false, temporary = true,
            omit_from_output = true, enabled = true }
        end
        ]]></script>
        </muclient>
        """
        let pluginB = """
        <muclient>
        <plugin id="com.b" name="B"/>
        <script><![CDATA[
        function OnPluginInstall() DeleteTemporaryTriggers() end
        ]]></script>
        </muclient>
        """
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: pluginA))
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: pluginB))
        // A's temporary trigger must survive B's DeleteTemporaryTriggers and still gag.
        #expect(await engine.process(line: "AAA").gag)
    }

    @Test("a saved variable round-trips back to the same plugin on reload")
    func reloadRoundTrip() async throws {
        // Session 1: load A + B, save state, snapshot variables (as on disk).
        let first = try ScriptEngine()
        _ = try await first.loadPlugin(plugin(id: "com.a"))
        _ = try await first.loadPlugin(plugin(id: "com.b"))
        _ = await first.disconnectPlugins()
        let saved = await first.variablesSnapshot()

        // Session 2 (fresh launch): hydrate the saved variables, then load A.
        // Its OnPluginInstall must read back the value IT saved, not B's.
        let second = try ScriptEngine()
        await second.loadVariables(saved)
        let effects = try await second.loadPlugin(plugin(id: "com.a"))
        #expect(effects.contains(.send("install:com.a")))
    }
}
