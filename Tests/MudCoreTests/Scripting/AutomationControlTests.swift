import Foundation
@testable import MudCore
import Testing

/// Trigger/alias/timer *control* world functions added to the generic shim from
/// the MUSHclient↔Proteles gap audit (Tier 2 quick wins): the option-name
/// getters `GetTriggerOption`/`GetAliasOption`/`GetTimerOption`, `SetAliasOption`,
/// `GetPluginTriggerInfo`, `StopEvaluatingTriggers`, and `TraceOut`/`SetStatus`.
/// Each test fails without the addition (the global would be a nil-call error, or
/// the option/halt/route would be wrong).
@Suite("Generic shim — automation control (gap Tier 2)")
struct AutomationControlTests {
    private func echoes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
    }

    private func traces(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { if case .trace(let text) = $0 { text } else { nil } }
    }

    // MARK: - Option-name getters (read the projected snapshot)

    @Test("GetTriggerOption/GetAliasOption read fields by MUSHclient option name")
    func optionGetters() async throws {
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
            sendText: "say hi",
            sendTo: 12
        )]
        snapshot.aliases = [AliasRecord(
            name: "al_y",
            owner: "p1",
            match: "^go$",
            isRegex: false,
            enabled: true,
            keepEvaluating: false,
            caseSensitive: true,
            sequence: 9,
            group: "ag",
            sendText: "north",
            sendTo: 0
        )]
        await lua.setAutomationSnapshot(snapshot)

        let effects = try await lua.run("""
        proteles.echo(tostring(GetTriggerOption("trig_x", "enabled")))         -- false
        proteles.echo(tostring(GetTriggerOption("trig_x", "omit_from_output"))) -- true (gag)
        proteles.echo(tostring(GetTriggerOption("trig_x", "ignore_case")))     -- true (not caseSensitive)
        proteles.echo(tostring(GetTriggerOption("trig_x", "sequence")))        -- 7
        proteles.echo(tostring(GetTriggerOption("trig_x", "group")))           -- grp
        proteles.echo(tostring(GetTriggerOption("trig_x", "bogus")))           -- nil
        proteles.echo(tostring(GetAliasOption("al_y", "match")))               -- ^go$
        proteles.echo(tostring(GetAliasOption("al_y", "ignore_case")))         -- false (caseSensitive)
        proteles.echo(tostring(GetAliasOption("al_y", "sequence")))            -- 9
        proteles.echo(tostring(GetAliasOption("absent", "enabled")))           -- nil
        """)
        #expect(echoes(effects) == [
            "false", "true", "true", "7", "grp", "nil", "^go$", "false", "9", "nil"
        ])
    }

    @Test("GetTimerOption reads shim-timer state (AddTimer doAfter chains)")
    func timerOption() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("""
        AddTimer("t1", 0, 0, 5, "", 1, "noop")   -- recurring 5s, Enabled
        proteles.echo(tostring(GetTimerOption("t1", "enabled")))   -- true
        proteles.echo(tostring(GetTimerOption("t1", "second")))    -- 5
        proteles.echo(tostring(GetTimerOption("t1", "one_shot")))  -- false
        proteles.echo(tostring(GetTimerOption("absent", "second")))-- nil
        """)
        #expect(echoes(effects) == ["true", "5", "false", "nil"])
    }

    @Test("GetPluginTriggerInfo is scoped to the named owner")
    func pluginTriggerInfo() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        var snapshot = AutomationSnapshot()
        snapshot.triggers = [
            record(name: "a", owner: "p1"),
            record(name: "c", owner: "p2")
        ]
        await lua.setAutomationSnapshot(snapshot)
        let effects = try await lua.run("""
        proteles.echo(tostring(GetPluginTriggerInfo("p1", "a", 1)))  -- ^a$ (owned by p1)
        proteles.echo(tostring(GetPluginTriggerInfo("p2", "a", 1)))  -- nil (a is p1's)
        proteles.echo(tostring(GetPluginTriggerInfo("p1", "c", 1)))  -- nil (c is p2's)
        proteles.echo(tostring(GetPluginTriggerInfo("p2", "c", 1)))  -- ^c$
        """)
        #expect(echoes(effects) == ["^a$", "nil", "nil", "^c$"])
    }

    // MARK: - SetAliasOption mutates the live alias engine

    @Test("SetAliasOption mutates a named alias (re-projects for the next read)")
    func setAliasOption() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: aliasPlugin))

        // keep_evaluating starts "n" (false); a later read reflects the write.
        #expect(await engine.process(line: "readopt").effects.contains(.send("ke=false")))
        // SetAliasOption("al", "keep_evaluating", "y") re-projects for the next read.
        _ = await engine.process(line: "setopt")
        #expect(await engine.process(line: "readopt").effects.contains(.send("ke=true")))
    }

    // MARK: - StopEvaluatingTriggers halts the per-line firing loop

    @Test("StopEvaluatingTriggers stops the remaining triggers firing on the line")
    func stopEvaluatingTriggers() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: stopPlugin))

        let effects = await engine.process(line: "both").effects
        #expect(effects.contains(.send("first"))) // the stopper (sequence 1) ran
        #expect(!effects.contains(.send("second"))) // the later trigger did NOT
    }

    // MARK: - TraceOut / SetStatus route to the transcript (no nil-global)

    @Test("TraceOut/SetStatus emit a trace effect rather than crashing")
    func traceAndStatus() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("""
        TraceOut("hello")
        SetStatus("walking")
        SetStatus("")
        """)
        #expect(traces(effects) == ["TraceOut: hello", "SetStatus: walking", "SetStatus: "])
    }

    // MARK: - Fixtures

    private let aliasPlugin = """
    <muclient>
    <plugin id="com.test.aliasopt" name="AliasOpt"/>
    <aliases>
      <alias name="al" match="^go$" enabled="y" keep_evaluating="n"><send>north</send></alias>
    </aliases>
    <triggers>
      <trigger name="setopt" enabled="y" regexp="y" match="^setopt$" send_to="12">
        <send>SetAliasOption("al", "keep_evaluating", "y")</send></trigger>
      <trigger name="readopt" enabled="y" regexp="y" match="^readopt$" send_to="12">
        <send>Send("ke=" .. tostring(GetAliasOption("al", "keep_evaluating")))</send></trigger>
    </triggers>
    </muclient>
    """

    private let stopPlugin = """
    <muclient>
    <plugin id="com.test.stop" name="Stop"/>
    <triggers>
      <trigger name="stopper" enabled="y" regexp="y" match="^both$" sequence="1"
               keep_evaluating="y" send_to="12"><send>
        StopEvaluatingTriggers()
        Send("first")
      </send></trigger>
      <trigger name="after" enabled="y" regexp="y" match="^both$" sequence="2"
               send_to="12"><send>Send("second")</send></trigger>
    </triggers>
    </muclient>
    """

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
