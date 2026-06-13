import Foundation
@testable import MudCore
import Testing

@Suite("ChatStore")
struct ChatStoreTests {
    private func commMessage(chan: String, msg: String, player: String = "") -> GMCPMessage {
        GMCPMessage(
            package: "comm.channel",
            json: #"{ "chan": "\#(chan)", "msg": "\#(msg)", "player": "\#(player)" }"#
        )
    }

    @Test("Ingests a comm.channel message into a styled chat line")
    func ingestsCommChannel() async {
        let store = ChatStore()
        let line = await store.ingest(commMessage(chan: "tell", msg: "@ghi there@w", player: "Bob"))
        #expect(line?.channel == "tell")
        #expect(line?.player == "Bob")
        #expect(line?.line.text == "hi there")
        #expect(await store.snapshot().count == 1)
    }

    @Test("Ignores non-comm.channel messages")
    func ignoresOthers() async {
        let store = ChatStore()
        let result = await store.ingest(GMCPMessage(package: "char.vitals", json: #"{"hp":1}"#))
        #expect(result == nil)
        #expect(await store.snapshot().isEmpty)
    }

    @Test("Assigns increasing ids")
    func increasingIDs() async {
        let store = ChatStore()
        let first = await store.append(channel: "chat", player: "", message: "one")
        let second = await store.append(channel: "chat", player: "", message: "two")
        #expect(second.id > first.id)
    }

    @Test("Bounded to maxLines, dropping oldest")
    func boundedCapacity() async {
        let store = ChatStore(maxLines: 2)
        await store.append(channel: "c", player: "", message: "1")
        await store.append(channel: "c", player: "", message: "2")
        await store.append(channel: "c", player: "", message: "3")
        let texts = await store.snapshot().map(\.line.text)
        #expect(texts == ["2", "3"])
    }

    @Test("restoreBatch re-seeds many lines in order, preserving timestamps")
    func restoreBatchSeedsBacklog() async {
        let store = ChatStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let rows = (0..<3).map { index in
            ChatLine(
                id: 0,
                timestamp: t0.addingTimeInterval(Double(index)),
                channel: "chat",
                player: "",
                line: Line(id: LineID(0), text: "old \(index)")
            )
        }
        await store.restoreBatch(rows)
        let snapshot = await store.snapshot()
        #expect(snapshot.map(\.line.text) == ["old 0", "old 1", "old 2"])
        #expect(snapshot.map(\.timestamp) == rows.map(\.timestamp)) // originals kept
        #expect(snapshot[0].id < snapshot[1].id) // fresh monotonic ids
    }

    @Test("channels() returns distinct names, sorted")
    func distinctChannels() async {
        let store = ChatStore()
        await store.append(channel: "tell", player: "", message: "a")
        await store.append(channel: "gossip", player: "", message: "b")
        await store.append(channel: "tell", player: "", message: "c")
        #expect(await store.channels() == ["gossip", "tell"])
    }

    @Test("subscribe delivers newly-appended lines")
    func subscribeDeliversNew() async {
        let store = ChatStore()
        let stream = await store.subscribe()
        var iterator = stream.makeAsyncIterator()
        await store.append(channel: "chat", player: "", message: "live")
        let received = await iterator.next()
        #expect(received?.line.text == "live")
    }

    @Test("reset clears the log")
    func resetClears() async {
        let store = ChatStore()
        await store.append(channel: "c", player: "", message: "x")
        await store.reset()
        #expect(await store.snapshot().isEmpty)
    }
}
