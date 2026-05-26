import Foundation
@testable import MudCore
import Testing

/// Load the REAL dinv into a REAL ``SessionController`` + ``InMemoryConnection``
/// and count how many times its command-queue fence echo is transmitted. Live
/// (and even the successful build) shows every dinv bypass send going out
/// twice; the dinv-*like* stub in other tests does not. This isolates whether
/// real dinv's coroutine-driven send path doubles through the real session.
@Suite("dinv — real plugin in real session (doubling)", .serialized)
struct DinvRealSessionTests {
    @Test("Real dinv's fence echo is transmitted once, not doubled")
    func fenceNotDoubled() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dinv-realsess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try ScriptEngine()
        await engine.registerModules(DinvAssets.modules)
        await engine.setSQLiteDirectory(dir.path)
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        // Seed the GMCP state dinv's init reads (active char), then arm + load
        // it; loadPendingDinv replays char.base to kick init (which fences).
        _ = await engine.applyGMCP(
            package: "char.status", json: #"{"level":150,"state":3,"pos":"Standing"}"#
        )
        _ = await engine.applyGMCP(package: "char.base", json: #"{"name":"Tester","class":"Mage"}"#)
        await controller.armBundledDinv(stateDirectory: dir.path)
        await controller.loadPendingDinv()

        // Drive dinv's real queue: auto-reply to each fence echo (like the MUD)
        // so the coroutine resumes and progresses, plus a prompt line — this is
        // the live condition under which sends were seen to double.
        var answered = Set<String>()
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            for line in conn.sentLines where line.hasPrefix("echo ") {
                let reply = String(line.dropFirst("echo ".count))
                if answered.insert(line).inserted { conn.injectLine(reply) }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let fenceSends = conn.sentLines.filter { $0.hasPrefix("echo { DINV fence") }
        // Each distinct fence tag should be sent exactly once.
        let counts = Dictionary(grouping: fenceSends, by: { $0 }).mapValues(\.count)
        let maxCount = counts.values.max() ?? 0
        #expect(maxCount <= 1, "dinv fence echo doubled: \(counts)")
        await controller.disconnect()
    }
}
