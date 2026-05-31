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
