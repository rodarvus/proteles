import Foundation
@testable import MudCore
import Testing

/// End-to-end exercise of the whole compat stack: parse a MUSHclient plugin,
/// load it (script + require + lifecycle), then drive GMCP and connect
/// callbacks and observe the effects — the way the live session does.
@Suite("ScriptEngine — plugin end-to-end")
struct PluginEndToEndTests {
    /// A prompt-fixer-shaped plugin: requires gmcphelper, reacts to the
    /// synthesised GMCP-handler broadcast, reads a GMCP value, and sends a
    /// GMCP packet — the exact mechanisms aard_prompt_fixer uses.
    private let promptish = """
    <muclient>
    <plugin id="com.test.promptish" name="Promptish" save_state="y"/>
    <script><![CDATA[
    require "gmcphelper"
    function OnPluginConnect()
      proteles.echo("connected as " .. tostring(IsConnected()))
    end
    function OnPluginBroadcast(msg, id, name, text)
      if id == "3e7dedbe37e44942dd46d264" and text == "char.status" then
        if gmcp("char.status.state") == "3" then
          Send_GMCP_Packet("request prompt")
        end
      end
    end
    ]]></script>
    </muclient>
    """

    /// A plugin whose broadcast handler kicks off a `wait.make` coroutine that
    /// yields on `wait.time` — exactly dinv's init shape. The yield schedules a
    /// resume timer via `AddTimer`; if the broadcast path drops that
    /// registration, the timer never fires and the coroutine hangs forever.
    private let waiter = """
    <muclient>
    <plugin id="com.test.waiter" name="Waiter" save_state="n"/>
    <script><![CDATA[
    require "wait"
    function OnPluginBroadcast(msg, id, name, text)
      if text == "char.status" then
        wait.make(function()
          wait.time(0.01)
          Send("resumed")
        end)
      end
    end
    ]]></script>
    </muclient>
    """

    @Test("A broadcast coroutine's wait.time resume timer is registered + fires")
    func broadcastCoroutineResumes() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: waiter)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)

        // The broadcast starts the coroutine, which yields on wait.time. The
        // resume timer must be consumed (registered), not dropped.
        _ = await engine.applyGMCP(package: "char.status", json: #"{"state":3}"#)
        #expect(await engine.nextTimerDeadline() != nil, "wait.time resume timer was never registered")

        // Firing the due timer resumes the coroutine, which then Sends.
        let resumed = await engine.fireDueTimers(at: Date().addingTimeInterval(1))
        #expect(resumed.contains(.send("resumed")), "coroutine did not resume after its timer fired")
    }

    @Test("A GMCP update drives the plugin's OnPluginBroadcast end-to-end")
    func gmcpDrivesBroadcast() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: promptish)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)

        // State 3 (standing) → the plugin requests the prompt.
        let effects = await engine.applyGMCP(package: "char.status", json: #"{"state":3}"#)
        #expect(effects.contains(.sendGMCP("request prompt")))
    }

    @Test("The broadcast is gated on the GMCP value (state != 3 → no send)")
    func broadcastGatedOnValue() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: promptish)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)

        let effects = await engine.applyGMCP(package: "char.status", json: #"{"state":8}"#)
        #expect(!effects.contains(.sendGMCP("request prompt")))
    }

    @Test("connectPlugins fires OnPluginConnect with live connection state")
    func connectLifecycle() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: promptish)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)
        await engine.setConnected(true)

        let effects = await engine.connectPlugins()
        #expect(effects == [.echo("connected as true")])
    }

    @Test("OnPluginScreendraw observes displayed output lines")
    func screendrawLifecycle() async throws {
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.test.screendraw" name="ScreenDraw"/>
        <script><![CDATA[
        function OnPluginScreendraw(t, log, line)
          AppendToNotepad("output", t, ":", tostring(log), ":", line, "\\r\\n")
          Note(GetNotepadText("output"))
        end
        ]]></script>
        </muclient>
        """)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)

        let effects = await engine.fireOnPluginScreendraw(type: 0, log: true, line: "hello")
        #expect(effects == [.echo("0:true:hello\r\n")])
    }

    @Test("No broadcast is synthesised when no plugin is loaded")
    func noBroadcastWithoutPlugins() async throws {
        let engine = try ScriptEngine()
        // Native gmcp projection still happens; no OnPluginBroadcast call.
        let effects = await engine.applyGMCP(package: "char.status", json: #"{"state":3}"#)
        #expect(effects.isEmpty)
    }

    // MARK: - Per-plugin environments

    private func plugin(id: String, send: String) throws -> MUSHclientPlugin {
        try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="\(id)" name="\(id)"/>
        <script><![CDATA[
        function OnPluginBroadcast(msg, handler, name, text)
          proteles.send("\(send)" .. text)
        end
        ]]></script>
        </muclient>
        """)
    }

    @Test("Two plugins defining the same global don't collide")
    func perPluginEnvironmentsIsolateGlobals() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(plugin(id: "com.a", send: "A:"))
        try await engine.loadPlugin(plugin(id: "com.b", send: "B:"))

        // Both plugins' OnPluginBroadcast fire (each in its own env) — under a
        // shared global table, B's definition would have clobbered A's.
        let effects = await engine.applyGMCP(package: "char.status", json: "{}")
        #expect(effects.contains(.send("A:char.status")))
        #expect(effects.contains(.send("B:char.status")))
    }

    @Test("A plugin trigger calls the plugin's own function, not another's")
    func ownerRoutedTriggerScripts() async throws {
        let engine = try ScriptEngine()
        let makePlugin = { (id: String, word: String) throws -> MUSHclientPlugin in
            try MUSHclientPluginLoader.parse(xml: """
            <muclient>
            <plugin id="\(id)" name="\(id)"/>
            <triggers>
            <trigger match="ping" keep_evaluating="y" send_to="12"><send>react()</send></trigger>
            </triggers>
            <script><![CDATA[ function react() proteles.echo("\(word)") end ]]></script>
            </muclient>
            """)
        }
        try await engine.loadPlugin(makePlugin("com.a", "A reacts"))
        try await engine.loadPlugin(makePlugin("com.b", "B reacts"))

        let disposition = await engine.process(line: "ping")
        // Each trigger ran its own plugin's react(), in its own env.
        #expect(disposition.effects.contains(.echo("A reacts")))
        #expect(disposition.effects.contains(.echo("B reacts")))
    }

    @Test("A trigger script gets a non-nil styles[]; GetNormalColour aligns with the run colour")
    func triggerStylesArgument() async throws {
        // The rsocial_capture case: a trigger callback `fn(name, line, wc, styles)`
        // that compares `styles[1].textcolour` to GetNormalColour values. styles
        // must be the matched line's colour runs, and GetNormalColour must agree
        // — with MUSHclient's ONE-based indexing (8 = white, 7 = cyan).
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.styles" name="Styles"/>
        <triggers>
        <trigger match="^hi$" enabled="y" regexp="y" script="capture" send_to="12"/>
        </triggers>
        <script><![CDATA[
        function capture(name, line, wc, styles)
          proteles.send("fg=" .. tostring(styles[1].textcolour) .. " white=" .. tostring(GetNormalColour(8)))
        end
        ]]></script>
        </muclient>
        """)
        try await engine.loadPlugin(plugin)
        var white = StyleAttributes.default
        white.foreground = .named(.white)
        let line = Line(id: LineID(0), text: "hi", runs: [StyledRun(utf16Range: 0..<2, style: white)])

        let disposition = await engine.process(line)

        // styles[1] is the white run, and its textcolour equals GetNormalColour(8)
        // (1-based: 8 is white; 7 is cyan — the 0-based table that once made
        // these differ broke rsocials' colour guard).
        #expect(disposition.effects.contains(.send("fg=12632256 white=12632256")))
    }

    @Test("OnPluginSend blocks a prefixed send and re-sends the bare command")
    func onPluginSendBypass() async throws {
        // Mirrors dinv's dbot.execute bypass: a DINV_BYPASS-prefixed line is
        // stripped + re-sent bare, and the prefixed original is dropped (false).
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.send.hook" name="SendHook"/>
        <script><![CDATA[
        function OnPluginSend(msg)
          local _, _, bare = string.find(msg, "DINV_BYPASS (.*)")
          if bare then SendNoEcho(bare); return false end
          return true
        end
        ]]></script>
        </muclient>
        """)
        let engine = try ScriptEngine()
        _ = await engine.loadPlugin(plugin)

        // A prefixed command is blocked, and the bare command comes back as a send.
        let bypass = await engine.fireOnPluginSend("DINV_BYPASS wear sword")
        #expect(bypass.blocked)
        #expect(bypass.effects.contains(.sendNoEcho("wear sword")))

        // A plain command is allowed (not blocked), no extra effects.
        let plain = await engine.fireOnPluginSend("look")
        #expect(!plain.blocked)
        #expect(plain.effects.isEmpty)
    }

    @Test("AddAlias on install registers a runtime alias that fires on input")
    func dynamicAliasFires() async throws {
        // dinv's regen pattern: register a `sleep` alias at install whose
        // handler runs in the plugin's env. Proves AddAlias → addDynamicAlias
        // → owner-scoped alias firing end-to-end.
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.dyn.alias" name="DynAlias"/>
        <script><![CDATA[
        function OnPluginInstall()
          AddAlias("dynSleep", "^sleep$", "",
                   alias_flag.Enabled + alias_flag.RegularExpression, "onSleep")
        end
        function onSleep() proteles.echo("regen!") end
        ]]></script>
        </muclient>
        """)
        let engine = try ScriptEngine()
        _ = await engine.loadPlugin(plugin)
        let effects = await engine.expandInput("sleep")
        #expect(effects.contains(.echo("regen!")))
        // A non-matching line is untouched.
        let none = await engine.expandInput("smile")
        #expect(!none.contains(.echo("regen!")))
    }
}

extension PluginEndToEndTests {
    @Test("GetPluginInfo(id, 19) returns the version (no concat-nil on install)")
    func getPluginInfoVersion() async throws {
        let xml = """
        <muclient>
        <plugin id="com.test.ver" name="Versioned" version="3.5"/>
        <script><![CDATA[
        function OnPluginInstall() Note("Installed v" .. GetPluginInfo(GetPluginID(), 19)) end
        function show() Note("name=" .. GetPluginInfo(GetPluginID(), 1)) end
        ]]></script>
        <aliases><alias match="show" enabled="y" script="show" send_to="12"/></aliases>
        </muclient>
        """
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let engine = try ScriptEngine()
        let install = await engine.loadPlugin(plugin)
        // OnPluginInstall ran without a concat-nil error and printed the version.
        #expect(install.contains { effect in
            if case .echo(let text) = effect { return text == "Installed v3.5" }
            return false
        })
        #expect(await engine.expandInput("show").contains(.echo("name=Versioned")))
    }

    @Test("GetPluginInfo(id, 3) returns the plugin description")
    func getPluginInfoDescription() async throws {
        let xml = """
        <muclient>
        <plugin id="com.test.desc" name="Described"/>
        <description trim="y"><![CDATA[
        Help from the description block.
        ]]></description>
        <aliases>
          <alias match="desc help" enabled="y" send_to="12">
            <send>Note(GetPluginInfo(GetPluginID(), 3))</send>
          </alias>
        </aliases>
        </muclient>
        """
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let engine = try ScriptEngine()
        await engine.loadPlugin(plugin)

        #expect(await engine.expandInput("desc help").contains(.echo("Help from the description block.")))
    }
}
