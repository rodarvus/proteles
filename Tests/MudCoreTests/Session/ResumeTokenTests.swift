import Foundation
@testable import MudCore
import Testing

@Suite("ResumeToken — session-resume breadcrumb (#42)")
struct ResumeTokenTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-resume-\(UUID().uuidString).json")
    }

    @Test("write → peek round-trips; take consumes (one-shot)")
    func writePeekTake() throws {
        let url = tempURL()
        let store = ResumeTokenStore(url: url)
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        let token = ResumeToken(worldID: id, appVersion: "0.4.9", stamp: stamp)

        try store.write(token)
        #expect(store.peek() == token) // peek doesn't consume
        #expect(store.peek() == token)
        #expect(store.take() == token) // take returns it…
        #expect(store.peek() == nil) // …and deletes it (one-shot)
        #expect(store.take() == nil)
    }

    @Test("isFresh: recent token honoured, stale or future ignored")
    func freshness() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let token = { (offset: TimeInterval) in
            ResumeToken(worldID: UUID(), appVersion: "0.4.9", stamp: now.addingTimeInterval(offset))
        }
        #expect(token(-5).isFresh(now: now)) // 5s old → fresh
        #expect(token(-119).isFresh(now: now)) // just under 2 min → fresh
        #expect(!token(-3600).isFresh(now: now)) // an hour old → stale (cold start)
        #expect(!token(+30).isFresh(now: now)) // future stamp → reject
    }

    @Test("wasUpdated: numeric-aware version compare (0.4.10 > 0.4.9)")
    func wasUpdated() {
        let token = ResumeToken(worldID: UUID(), appVersion: "0.4.9", stamp: Date())
        #expect(token.wasUpdated(runningVersion: "0.4.10")) // newer (numeric, not lexical)
        #expect(token.wasUpdated(runningVersion: "0.5.0"))
        #expect(!token.wasUpdated(runningVersion: "0.4.9")) // same → quick restart
        #expect(!token.wasUpdated(runningVersion: "0.4.8")) // older → not an update
    }

    @Test("missing / corrupt file reads as nil, never throws on read")
    func missingAndCorrupt() throws {
        let url = tempURL()
        let store = ResumeTokenStore(url: url)
        #expect(store.peek() == nil) // absent
        try Data("not json".utf8).write(to: url)
        #expect(store.peek() == nil) // corrupt → nil, no throw
        store.clear()
        #expect(store.peek() == nil)
    }
}
