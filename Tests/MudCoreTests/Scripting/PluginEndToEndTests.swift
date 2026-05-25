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
}
