@testable import MudCore
import Testing

/// `SaveState()` must refuse re-entry, as MUSHclient does
/// (`methods_plugins.cpp:509`: "if we are already saving the state, don't do it
/// again" → `ePluginCouldNotSaveState` while `m_bSavingStateNow`).
///
/// Regression for #86. A plugin's save routine commonly calls `SaveState()`,
/// and its `OnPluginSaveState` calls that same routine. Without the guard the
/// two recursed until Lua's C stack overflowed inside `pcall` — ~200 levels,
/// each re-serialising the plugin's state — on **every** trigger that saved.
/// Measured: 167 ms per kill line on a 67-day history table, growing a row a
/// day, which was the two-week drift the recordings showed.
@Suite("SaveState re-entry guard (#86)")
struct SaveStateReentryTests {
    /// The shape that recursed: a save routine that calls `SaveState()`, and a
    /// save callback that calls the save routine. `saves` counts the routine.
    private func plugin() throws -> MUSHclientPlugin {
        try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.test.reentry" name="Reentry"/>
        <script><![CDATA[
        saves = 0
        nestedCode = nil
        function SaveTotal()
          saves = saves + 1
          SetVariable("total", tostring(saves))
          local code = SaveState()
          if saves > 1 and nestedCode == nil then nestedCode = code end
        end
        function OnPluginSaveState()
          SaveTotal()
        end
        ]]></script>
        </muclient>
        """)
    }

    @Test("A scripted SaveState() runs the save callback once, and the nested call is refused")
    func scriptedSaveRunsCallbackOnce() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(plugin())

        // One save from script: the routine runs, SaveState() runs the callback,
        // the callback's own SaveState() is refused. Two routine calls, not ~200.
        _ = await engine.evaluateConsole("SaveTotal()", inPlugin: "com.test.reentry")
        let report = await engine.evaluateConsole(
            "proteles.echo(tostring(saves) .. ' ' .. tostring(nestedCode))",
            inPlugin: "com.test.reentry"
        )
        #expect(report.contains(.echo("2 30037")), "\(report)")
    }

    @Test("The refusal code is MUSHclient's ePluginCouldNotSaveState")
    func refusalCodeMatchesReference() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(plugin())
        let report = await engine.evaluateConsole(
            "proteles.echo(tostring(error_code.ePluginCouldNotSaveState))",
            inPlugin: "com.test.reentry"
        )
        #expect(report.contains(.echo("30037")), "\(report)")
    }

    /// A host-initiated save (disconnect, unload) calls the callback directly,
    /// so the callback's own SaveState() runs it once more before the guard
    /// engages: two routine calls, bounded, and the variable still lands.
    @Test("A host-initiated save stays bounded and persists the variable")
    func hostSaveIsBounded() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(plugin())
        _ = await engine.disconnectPlugins()
        let report = await engine.evaluateConsole(
            "proteles.echo(tostring(saves))",
            inPlugin: "com.test.reentry"
        )
        #expect(report.contains(.echo("2")), "\(report)")
        let snapshot = await engine.variablesSnapshot()
        #expect(snapshot["com.test.reentry"]?["total"] == "2")
    }

    /// The guard is per call, not sticky: a second scripted save after the
    /// first completes behaves the same way.
    @Test("The guard clears after the save completes")
    func guardClearsAfterSave() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(plugin())
        _ = await engine.evaluateConsole("SaveTotal()", inPlugin: "com.test.reentry")
        _ = await engine.evaluateConsole("SaveTotal()", inPlugin: "com.test.reentry")
        let report = await engine.evaluateConsole(
            "proteles.echo(tostring(saves))",
            inPlugin: "com.test.reentry"
        )
        #expect(report.contains(.echo("4")), "\(report)")
    }
}
