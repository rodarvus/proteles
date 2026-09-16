import Foundation
@testable import MudCore
import Testing

/// The host must not infer capture ownership from a bypassed command. The
/// bundled plugin's narrow parser owns suppression; no generic 80-line gag.
@Suite("wish-probe host boundary", .serialized)
struct WishProbeHostGagTests {
    /// A plugin that, like dinv, re-sends `wish list` from *inside* `OnPluginSend`
    /// (the bypass path) — but registers NO gag trigger of its own, so the gag
    /// here can only come from the host.
    private let probePlugin = """
    <muclient><plugin id="com.test.wishprobe" name="WishProbe"/>
    <script><![CDATA[
    function OnPluginSend(cmd)
      if cmd == "probe" then SendNoEcho("wish list") end
    end
    ]]></script></muclient>
    """

    private func connectedController(
        plugin: String
    ) async throws -> (SessionController, InMemoryConnection) {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))
        return (controller, conn)
    }

    private let wishOutput = [
        "                                    Base Cost Adjustment Your Cost  Keyword",
        "*Very fast spell-up time                 6000        250        -- Spellup    ",
        " No hunger or thirst                     3000          0      3000 Nohunger  ",
        "*Add +1 bypass (all classes)             6000        250        -- Bypass     ",
        "Refer to 'help wish' for a description of each wish."
    ]

    @Test("A bypassed wish command does not arm a host-wide output gag")
    func bypassDoesNotCaptureOutput() async throws {
        let (controller, _) = try await connectedController(plugin: probePlugin)
        try await controller.send("probe")
        for text in wishOutput + ["You say 'hello'."] {
            await controller.appendLineThroughScripts(Line(id: LineID(0), text: text))
        }
        let shown = await controller.scrollbackStore.snapshot().map(\.text)
        #expect(shown.contains { $0.contains("Spellup") })
        #expect(shown.contains { $0.contains("Nohunger") })
        #expect(shown.contains("You say 'hello'."))
        await controller.disconnect()
    }

    @Test("a user-typed `wish list` is NOT gagged")
    func userTypedWishListShows() async throws {
        // No plugin re-send: the user types `wish list` themselves.
        let (controller, _) = try await connectedController(plugin: """
        <muclient><plugin id="com.test.nohook" name="NoHook"/>
        <script><![CDATA[ function OnPluginInstall() end ]]></script></muclient>
        """)
        try await controller.send("wish list")
        for text in wishOutput {
            await controller.appendLineThroughScripts(Line(id: LineID(0), text: text))
        }
        let shown = await controller.scrollbackStore.snapshot().map(\.text)
        // The user asked for it → it must show (a user-typed command has
        // pluginProcessingSend false, so the probe gag never arms).
        #expect(shown.contains { $0.contains("Spellup") }, "user-typed wish list was gagged: \(shown)")
        await controller.disconnect()
    }
}
