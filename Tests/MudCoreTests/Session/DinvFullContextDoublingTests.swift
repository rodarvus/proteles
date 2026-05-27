import Foundation
@testable import MudCore
import Testing

/// Non-vacuous reproduction of the live "every dinv bypass send goes out twice"
/// defect. Earlier dinv "real session" tests were *vacuous*: dinv spins ~5s per
/// `getConfig` (we never deliver the `config` GMCP to its telnet-sub callback,
/// so each times out), so within a 4s budget it never reached its fence stage
/// and no `echo { DINV fence N }` was ever sent — the doubling assertion passed
/// trivially. This gives dinv the ~15s it needs to time through config and run
/// its real fence loop, with the app's native plugins registered, then counts
/// each distinct fence send. Live every such send doubled.
@Suite("dinv — full-context doubling repro", .serialized)
struct DinvFullContextDoublingTests {
    init() {
        SnDFixture.install()
    }

    /// A user plugin defining OnPluginSend (mirrors the user's aard_autobypass:
    /// it only acts on campaign-request commands, ignoring DINV_BYPASS).
    private let userPlugin = """
    <muclient><plugin id="com.test.userbypass" name="UserBypass"/>
    <script><![CDATA[
    function OnPluginSend(cmd)
      local f = string.match(string.lower(cmd), "^(%S+)")
      if f == "cp" or f == "campaign" then SendNoEcho("bypass north") end
    end
    ]]></script></muclient>
    """

    /// Register the app's launch-time native plugins (AardGMCPHandler powers
    /// dinv's `sendgmcp`; the rest match the live set) + dinv's modules.
    private func registerAppPlugins(on engine: ScriptEngine, dir: URL) async throws {
        await engine.registerNativePlugin(AardGMCPHandler())
        await engine.registerNativePlugin(VitalShortcuts())
        await engine.registerNativePlugin(NoteMode())
        await engine.registerNativePlugin(TextSubstitution())
        await engine.registerNativePlugin(ChatEcho())
        await engine.registerNativePlugin(AsciiMap())
        await engine.registerNativePlugin(TickTimer())
        await engine.registerNativePlugin(URLLinkify())
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: userPlugin))
        await engine.registerModules(DinvAssets.modules)
        await engine.setSQLiteDirectory(dir.path)
    }

    @Test("Real dinv's fence echo is sent once (non-vacuous, full plugin set)", .timeLimit(.minutes(1)))
    func fenceNotDoubledFullContext() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dinv-fullctx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try ScriptEngine()
        try await registerAppPlugins(on: engine, dir: dir)

        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        // Attach a live mapper + S&D host, like the app does per world — so their
        // timers share dinv's timer loop (the untested concurrency).
        let mapURL = dir.appendingPathComponent("map.db")
        if let mapper = try? Mapper(store: MapperStore(url: mapURL)) {
            await controller.attachMapper(mapper)
        }
        if let host = try? SearchAndDestroyHost() {
            await host.configure(directory: dir.path)
            try? await host.load()
            await controller.attachSearchAndDestroy(host)
        }
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Seed the active char state dinv keys init on, then arm + load it.
        await controller.dispatchGMCP(GMCPMessage(
            package: "char.status", json: #"{"level":150,"state":3,"pos":"Standing"}"#
        ))
        await controller.armBundledDinv(stateDirectory: dir.path)
        await controller.loadPendingDinv()

        // Drive dinv to (and through) its fence loop: keep the active state warm,
        // auto-reply to each fence echo like the MUD, and give it ~16s to time
        // through the two config getters and start fencing.
        var answered = Set<String>()
        let deadline = ContinuousClock.now.advanced(by: .seconds(18))
        var tick = 0
        while ContinuousClock.now < deadline {
            tick += 1
            if tick % 25 == 0 {
                await controller.dispatchGMCP(GMCPMessage(
                    package: "char.status", json: #"{"level":150,"state":3,"pos":"Standing"}"#
                ))
            }
            for line in conn.sentLines where line.hasPrefix("echo ") {
                let reply = String(line.dropFirst("echo ".count))
                if answered.insert(line).inserted { conn.injectLine(reply) }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let fenceSends = conn.sentLines.filter { $0.hasPrefix("echo { DINV fence") }
        let counts = Dictionary(grouping: fenceSends, by: { $0 }).mapValues(\.count)
        let maxCount = counts.values.max() ?? 0
        #expect(!fenceSends.isEmpty, "VACUOUS: dinv never reached its fence loop: \(conn.sentLines)")
        #expect(maxCount <= 1, "dinv fence echo doubled under full context: \(counts)")
        await controller.disconnect()
    }
}
