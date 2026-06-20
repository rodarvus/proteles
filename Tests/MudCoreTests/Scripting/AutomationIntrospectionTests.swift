import Foundation
@testable import MudCore
import Testing

/// Trigger/alias/timer introspection world functions added to the generic
/// shim from the MUSHclient↔Proteles gap audit (Tier 2): `GetTriggerInfo`/
/// `GetAliasInfo`/`GetTimerInfo`, the `Get*List` family, `GetPluginTriggerList`,
/// and `ResetTimer`. Broadly used by plugin developers to render and reflect on
/// their own automation. Each test fails without the addition (the global would
/// be a nil-call error, or the field/list would be wrong).
@Suite("Generic shim — automation introspection (gap Tier 2)")
struct AutomationIntrospectionTests {
    /// Only the `.echo` payloads, in order — automation calls (AddTimer/
    /// ResetTimer) also record `.scheduleAfter`, which we don't assert on.
    private func echoes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
    }

    // MARK: - Unit: the host query reads the projected snapshot

    @Test("GetTriggerInfo returns each MUSHclient InfoType field, nil for unknown")
    func triggerInfoFields() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        var snapshot = AutomationSnapshot()
        snapshot.triggers = [TriggerRecord(
            name: "trig_x",
            owner: "p1",
            match: "^hi$",
            isRegex: true,
            enabled: false,
            gag: true,
            keepEvaluating: true,
            caseSensitive: false,
            sequence: 7,
            oneShot: false,
            group: "grp",
            script: "fn",
            sendText: "",
            sendTo: 12
        )]
        await lua.setAutomationSnapshot(snapshot)

        let effects = try await lua.run("""
        proteles.echo(tostring(GetTriggerInfo("trig_x", 1)))   -- match
        proteles.echo(tostring(GetTriggerInfo("trig_x", 8)))   -- enabled
        proteles.echo(tostring(GetTriggerInfo("trig_x", 9)))   -- regex
        proteles.echo(tostring(GetTriggerInfo("trig_x", 10)))  -- ignore_case (= not caseSensitive)
        proteles.echo(tostring(GetTriggerInfo("trig_x", 16)))  -- sequence
        proteles.echo(tostring(GetTriggerInfo("trig_x", 26)))  -- group
        proteles.echo(tostring(GetTriggerInfo("trig_x", 6)))   -- omit_from_output
        proteles.echo(tostring(GetTriggerInfo("absent", 1)))   -- unknown name -> nil
        proteles.echo(tostring(GetTriggerInfo("trig_x", 99)))  -- untracked field -> nil
        """)
        #expect(echoes(effects) == [
            "^hi$", "false", "true", "true", "7", "grp", "true", "nil", "nil"
        ])
    }

    @Test("GetPluginTriggerList returns the named plugin's trigger names; nil when none")
    func pluginTriggerList() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        var snapshot = AutomationSnapshot()
        snapshot.triggers = [
            record(name: "a", owner: "p1"),
            record(name: "b", owner: "p1"),
            record(name: "c", owner: "p2")
        ]
        await lua.setAutomationSnapshot(snapshot)

        let effects = try await lua.run("""
        local p1 = GetPluginTriggerList("p1")
        proteles.echo("p1=" .. table.concat(p1, ","))
        proteles.echo("p1n=" .. tostring(#p1))
        proteles.echo("p2=" .. table.concat(GetPluginTriggerList("p2"), ","))
        proteles.echo("none=" .. tostring(GetPluginTriggerList("nobody")))
        """)
        #expect(echoes(effects) == ["p1=a,b", "p1n=2", "p2=c", "none=nil"])
    }

    @Test("GetTimerInfo/ResetTimer read shim-timer state (AddTimer doAfter chains)")
    func timerShimIntrospection() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        // A recurring (non-OneShot) 5s timer; flags=1 means Enabled.
        let effects = try await lua.run("""
        AddTimer("t1", 0, 0, 5, "", 1, "noop")
        proteles.echo(tostring(GetTimerInfo("t1", 6)))             -- enabled
        proteles.echo(tostring(GetTimerInfo("t1", 3)))             -- seconds
        proteles.echo(tostring(GetTimerInfo("t1", 7)))             -- one-shot? (no)
        proteles.echo(tostring(ResetTimer("t1") == error_code.eOK))
        proteles.echo(tostring(GetTimerInfo("absent", 6)))         -- unknown -> nil
        """)
        #expect(echoes(effects) == ["true", "5", "false", "true", "nil"])
    }

    // MARK: - End to end: projection from a loaded plugin's live engines

    /// A "probe" trigger reads back the sibling "react" trigger and the plugin's
    /// own trigger list — the real shape of a plugin that prints its triggers.
    private let plugin = """
    <muclient>
    <plugin id="com.test.introspect" name="Introspect"/>
    <triggers>
      <trigger name="react" enabled="y" regexp="y" match="^hello there$"
               sequence="42" send_to="12"><send></send></trigger>
      <trigger name="probe" enabled="y" regexp="y" match="^probe$" send_to="12"><send>
        Send("match=" .. tostring(GetTriggerInfo("react", 1)))
        Send("enabled=" .. tostring(GetTriggerInfo("react", 8)))
        Send("seq=" .. tostring(GetTriggerInfo("react", 16)))
        Send("regex=" .. tostring(GetTriggerInfo("react", 9)))
        local list = GetPluginTriggerList(GetPluginID())
        local found = false
        for _, n in ipairs(list or {}) do if n == "react" then found = true end end
        Send("found=" .. tostring(found))
      </send></trigger>
      <trigger name="disable" enabled="y" regexp="y" match="^disable$" send_to="12">
        <send>EnableTrigger("react", false)</send></trigger>
    </triggers>
    </muclient>
    """

    @Test("GetTriggerInfo/GetPluginTriggerList reflect an XML plugin's live triggers")
    func endToEndProjection() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))

        let disposition = await engine.process(line: "probe")
        #expect(disposition.effects.contains(.send("match=^hello there$")))
        #expect(disposition.effects.contains(.send("enabled=true")))
        #expect(disposition.effects.contains(.send("seq=42")))
        #expect(disposition.effects.contains(.send("regex=true")))
        #expect(disposition.effects.contains(.send("found=true")))
    }

    @Test("GetTriggerInfo enabled-state re-projects after EnableTrigger (dirty flag)")
    func reprojectsAfterMutation() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))

        #expect(await engine.process(line: "probe").effects.contains(.send("enabled=true")))
        _ = await engine.process(line: "disable") // EnableTrigger("react", false)
        #expect(await engine.process(line: "probe").effects.contains(.send("enabled=false")))
    }

    private func record(name: String, owner: String) -> TriggerRecord {
        TriggerRecord(
            name: name,
            owner: owner,
            match: "^\(name)$",
            isRegex: true,
            enabled: true,
            gag: false,
            keepEvaluating: true,
            caseSensitive: false,
            sequence: 100,
            oneShot: false,
            group: "",
            script: "",
            sendText: "",
            sendTo: 0
        )
    }
}
