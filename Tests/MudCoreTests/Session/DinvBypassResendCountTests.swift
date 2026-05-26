import Foundation
@testable import MudCore
import Testing

/// Decisive isolation of the live "every dinv bypass send goes out twice"
/// defect. The full-session ``DinvFullContextDoublingTests`` drives dinv's real
/// fence loop; this drives ``ScriptEngine/fireOnPluginSend(_:)`` directly — the
/// exact hook dinv's bypass routes through — to pin whether the duplicate
/// resend originates *inside* the engine hook (it does not) and whether a
/// double-load could put dinv in `loadedPluginIDs` twice (it cannot).
@Suite("dinv — bypass resend count", .serialized)
struct DinvBypassResendCountTests {
    private func resendCount(_ effects: [ScriptEffect]) -> Int {
        effects.count { effect in
            switch effect {
            case .send, .sendNoEcho: true
            default: false
            }
        }
    }

    private func dinvContext(dir: URL) -> PluginContext {
        let path = dir.path + "/"
        return PluginContext(
            pluginID: DinvAssets.pluginID,
            pluginName: "dinv",
            version: "3.0102",
            pluginDirectory: path,
            worldDirectory: path,
            appDirectory: path,
            stateDirectory: path
        )
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dinv-resend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Load real dinv the way ``SessionController/loadPendingDinv()`` does, then
    /// register the same native plugins the app registers at launch. A single
    /// `DINV_BYPASS echo X` offered to the send hook must yield exactly ONE bare
    /// resend (dinv strips the prefix once); >1 would reproduce the doubling.
    @Test("fireOnPluginSend returns exactly one resend for a DINV_BYPASS")
    func bypassResendIsNotDuplicated() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try ScriptEngine()
        // Mirror the app's launch-time native-plugin registration.
        await engine.registerNativePlugin(AardGMCPHandler())
        await engine.registerNativePlugin(VitalShortcuts())
        await engine.registerNativePlugin(NoteMode())
        await engine.registerNativePlugin(TextSubstitution())
        await engine.registerNativePlugin(ChatEcho())
        await engine.registerNativePlugin(AsciiMap())
        await engine.registerNativePlugin(TickTimer())
        await engine.registerNativePlugin(URLLinkify())

        await engine.registerModules(DinvAssets.modules)
        await engine.setSQLiteDirectory(dir.path)
        let xml = try #require(DinvAssets.pluginXML)
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        _ = await engine.loadPlugin(plugin, context: dinvContext(dir: dir))

        let (blocked, effects) = await engine.fireOnPluginSend("DINV_BYPASS echo X")
        let count = resendCount(effects)
        #expect(
            count == 1,
            "DINV_BYPASS produced \(count) resends (blocked=\(blocked)): \(effects)"
        )
    }

    /// If a `char.base`-driven race loaded dinv twice, `loadedPluginIDs` would
    /// hold its id twice and the send hook would strip+resend the bypass twice.
    /// Loading the same plugin twice must be idempotent (one resend).
    @Test("Loading dinv twice does not duplicate the bypass resend")
    func doubleLoadIsIdempotent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try ScriptEngine()
        await engine.registerModules(DinvAssets.modules)
        await engine.setSQLiteDirectory(dir.path)
        let xml = try #require(DinvAssets.pluginXML)
        let first = try MUSHclientPluginLoader.parse(xml: xml)
        let second = try MUSHclientPluginLoader.parse(xml: xml)
        _ = await engine.loadPlugin(first, context: dinvContext(dir: dir))
        _ = await engine.loadPlugin(second, context: dinvContext(dir: dir))

        let (_, effects) = await engine.fireOnPluginSend("DINV_BYPASS echo X")
        let count = resendCount(effects)
        #expect(count == 1, "double-loaded dinv produced \(count) resends: \(effects)")
    }

    /// Regression for the live doubling root cause: dinv's modules are loaded via
    /// `dofile`, which (pre-fix) ran them in the shared `_G` rather than dinv's
    /// env, leaking dinv's `OnPluginSend` into `_G`. A *co-loaded* plugin that
    /// defines no `OnPluginSend` of its own then inherited dinv's via `__index`,
    /// so the send hook stripped + re-sent each bypass once per such plugin —
    /// every dinv bypass was transmitted twice live. With the dofile env fix,
    /// dinv's `OnPluginSend` stays in its own env and the co-loaded plugin adds
    /// nothing: exactly one resend.
    @Test("A co-loaded plugin without OnPluginSend doesn't inherit dinv's (no doubling)")
    func coLoadedPluginDoesNotInheritDinvHook() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try ScriptEngine()
        // A plugin with NO OnPluginSend (mirrors the user's Proteles_Demo), loaded
        // alongside dinv. Pre-fix this slot inherited dinv's leaked _G.OnPluginSend.
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.test.nohook" name="NoHook"/>
        <script><![CDATA[ function OnPluginInstall() end ]]></script></muclient>
        """))
        await engine.registerModules(DinvAssets.modules)
        await engine.setSQLiteDirectory(dir.path)
        let xml = try #require(DinvAssets.pluginXML)
        let dinv = try MUSHclientPluginLoader.parse(xml: xml)
        _ = await engine.loadPlugin(dinv, context: dinvContext(dir: dir))

        let (_, effects) = await engine.fireOnPluginSend("DINV_BYPASS echo X")
        let count = resendCount(effects)
        #expect(count == 1, "co-loaded hook-less plugin caused \(count) resends: \(effects)")
    }
}
