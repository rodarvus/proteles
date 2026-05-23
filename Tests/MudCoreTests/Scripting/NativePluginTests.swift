import Foundation
@testable import MudCore
import Testing

/// A command-only native plugin: `ping` → echo "pong"; exposes `answer`.
private struct PingPlugin: NativePlugin {
    let metadata = NativePluginMetadata(id: "test.ping", name: "Ping")

    func handleCommand(_ input: String) -> [ScriptEffect]? {
        input == "ping" ? [.echo("pong")] : nil
    }

    func onGMCP(package: String, json _: String) -> [ScriptEffect] {
        package == "char.vitals" ? [.echo("vitals updated")] : []
    }

    func call(_ function: String, _: [LuaValue]) -> [LuaValue] {
        function == "answer" ? [.number(42)] : []
    }
}

/// A line-reactor that gags spam and echoes a marker for greetings.
private struct LineWatcherPlugin: NativePlugin {
    let metadata = NativePluginMetadata(id: "test.lines", name: "Lines")

    func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        if line.text.contains("SPAM") { return .init(gag: true) }
        if line.text.contains("hello") { return .init(effects: [.echo("greeted")]) }
        return .init()
    }
}

@Suite("NativePluginRegistry — folding native plugins")
struct NativePluginRegistryTests {
    @Test("A registered command plugin handles its command; others pass through")
    func handleCommand() {
        var registry = NativePluginRegistry()
        registry.register(PingPlugin())
        #expect(registry.handleCommand("ping") == [.echo("pong")])
        #expect(registry.handleCommand("look") == nil)
    }

    @Test("onLine folds gags and effects across enabled plugins")
    func onLine() {
        var registry = NativePluginRegistry()
        registry.register(LineWatcherPlugin())
        #expect(registry.onLine(line("SPAM ad")).gag == true)
        #expect(registry.onLine(line("hello there")).effects == [.echo("greeted")])
        #expect(registry.onLine(line("plain")).effects.isEmpty)
    }

    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    @Test("Disabling a plugin stops it handling commands; re-enabling restores it")
    func enableDisable() {
        var registry = NativePluginRegistry()
        registry.register(PingPlugin())
        registry.setEnabled(false, id: "test.ping")
        #expect(registry.handleCommand("ping") == nil)
        registry.setEnabled(true, id: "test.ping")
        #expect(registry.handleCommand("ping") == [.echo("pong")])
    }

    @Test("call routes to the plugin's callable surface by id")
    func callableSurface() {
        var registry = NativePluginRegistry()
        registry.register(PingPlugin())
        #expect(registry.call(id: "test.ping", function: "answer", arguments: []) == [.number(42)])
        #expect(registry.call(id: "test.ping", function: "missing", arguments: []).isEmpty)
        #expect(registry.call(id: "nope", function: "answer", arguments: []).isEmpty)
    }

    @Test("Listing reflects registration order and enabled state")
    func listing() {
        var registry = NativePluginRegistry()
        registry.register(PingPlugin())
        registry.register(LineWatcherPlugin(), enabled: false)
        let listing = registry.listing
        #expect(listing.map(\.metadata.id) == ["test.ping", "test.lines"])
        #expect(listing.map(\.enabled) == [true, false])
    }

    @Test("Listing carries each plugin's help (default empty when unprovided)")
    func listingHelp() {
        var registry = NativePluginRegistry()
        registry.register(PingPlugin())
        registry.register(VitalShortcuts())
        let listing = registry.listing
        // PingPlugin provides no help → the default.
        #expect(listing[0].help == .none)
        // VitalShortcuts documents its commands.
        #expect(listing[1].help.commands.isEmpty == false)
        #expect(listing[1].help.commands.contains { $0.syntax.contains("vitals") })
    }
}

@Suite("ScriptEngine — native plugin integration")
struct ScriptEngineNativePluginTests {
    @Test("A native command is intercepted instead of being sent to the MUD")
    func commandIntercepted() async throws {
        let engine = try ScriptEngine()
        await engine.registerNativePlugin(PingPlugin())
        #expect(await engine.expandInput("ping") == [.echo("pong")])
        // Unhandled input still goes to the MUD verbatim.
        #expect(await engine.expandInput("north") == [.send("north")])
    }

    @Test("A native plugin reacts to incoming lines through process()")
    func lineReaction() async throws {
        let engine = try ScriptEngine()
        await engine.registerNativePlugin(LineWatcherPlugin())
        let gagged = await engine.process(line: "SPAM advertisement")
        #expect(gagged.gag == true)
        let greeted = await engine.process(line: "hello world")
        #expect(greeted.effects == [.echo("greeted")])
    }

    @Test("A native plugin reacts to GMCP updates through applyGMCP()")
    func gmcpReaction() async throws {
        let engine = try ScriptEngine()
        await engine.registerNativePlugin(PingPlugin())
        let effects = await engine.applyGMCP(package: "char.vitals", json: "{}")
        #expect(effects.contains(.echo("vitals updated")))
    }

    @Test("callNativePlugin routes to the plugin by id")
    func callRouting() async throws {
        let engine = try ScriptEngine()
        await engine.registerNativePlugin(PingPlugin())
        let result = await engine.callNativePlugin(id: "test.ping", function: "answer", arguments: [])
        #expect(result == [.number(42)])
    }
}
