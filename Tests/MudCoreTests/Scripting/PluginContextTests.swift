import Foundation
@testable import MudCore
import Testing

@Suite("PluginContext — GetInfo subset")
struct PluginContextTests {
    private let context = PluginContext(
        pluginID: "com.x.plugin",
        pluginName: "X",
        pluginDirectory: "/plugins/x",
        worldName: "Aardwolf",
        worldDirectory: "/worlds/aard",
        appDirectory: "/app",
        stateDirectory: "/state",
        soundsDirectory: "/sounds",
        logDirectory: "/logs"
    )

    @Test("Path and identity codes resolve to their directories")
    func pathCodes() {
        #expect(context.info(2) == .text("Aardwolf")) // world name
        #expect(context.info(66) == .text("/app")) // app dir (per-character data)
        #expect(context.info(60) == .text("/plugins/x")) // plugin dir
        // GetInfo(56) maps to the plugin's OWN folder, not the data dir, so a
        // plugin's `GetInfo(56) .. "x.txt"` config is global-per-plugin (see
        // the message gagger). Split from 66 deliberately.
        #expect(context.info(56) == .text("/plugins/x")) // plugin dir (not /app)
        #expect(context.info(64) == .text("/plugins/x")) // current dir
        #expect(context.info(67) == .text("/worlds/aard")) // world dir
        #expect(context.info(74) == .text("/sounds")) // sounds
        #expect(context.info(85) == .text("/state")) // state
    }

    @Test("Flag codes resolve to booleans")
    func flagCodes() {
        #expect(context.info(113) == .flag(true)) // world active
        #expect(context.info(114) == .flag(false)) // not paused
        #expect(context.info(120) == .flag(true)) // scrollbar visible
    }

    @Test("Time code resolves to the supplied instant")
    func timeCode() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(context.info(304, now: now) == .number(1_700_000_000))
    }

    @Test("Unimplemented codes return nil")
    func unknownCode() {
        #expect(context.info(99999) == nil)
    }
}

@Suite("LuaRuntime — proteles.info / pluginID")
struct LuaRuntimeInfoTests {
    @Test("proteles.info returns typed values for known codes")
    func infoTyped() async throws {
        let lua = try LuaRuntime()
        await lua.setPluginContext(PluginContext(
            pluginID: "p", pluginName: "P", appDirectory: "/app"
        ))
        #expect(try await lua.string("proteles.info(66)") == "/app")
        #expect(try await lua.boolean("proteles.info(113) == true"))
        #expect(try await lua.boolean("proteles.info(99999) == nil"))
    }

    @Test("proteles.pluginID returns the current plugin id")
    func pluginID() async throws {
        let lua = try LuaRuntime()
        await lua.setPluginContext(PluginContext(pluginID: "com.x.y", pluginName: "Y"))
        #expect(try await lua.string("proteles.pluginID()") == "com.x.y")
        // Defaults to the user scope without a context set.
        let fresh = try LuaRuntime()
        #expect(try await fresh.string("proteles.pluginID()") == "_user")
    }
}
