import Foundation
import MudCore
@testable import MudUI
import Testing

@MainActor
@Suite("ChatModel typed source filtering")
struct ChatModelTests {
    @Test("source filters, unread counts, and All acknowledgement")
    func filtersAndUnread() async throws {
        let store = ChatStore()
        let model = ChatModel(store: store)
        await model.start()
        model.select(.channel("tell"))
        await store.append(channel: "tell", player: "Bob", message: "one")
        await store.append(source: .nonChannel(.info), message: "INFO: two")
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.filteredLines.map(\.line.text) == ["one"])
        #expect(model.unread[.nonChannel(.info)] == 1)
        model.select(.nonChannel(.info))
        #expect(model.filteredLines.map(\.line.text) == ["INFO: two"])
        #expect(model.unread[.nonChannel(.info)] == nil)
        model.select(nil)
        #expect(model.unread.isEmpty)
    }

    @Test("clear current source leaves other source buffers intact")
    func clearSource() async {
        let store = ChatStore()
        await store.append(channel: "tell", player: "Bob", message: "one")
        await store.append(source: .nonChannel(.info), message: "INFO: two")
        let model = ChatModel(store: store)
        await model.start()
        model.select(.nonChannel(.info))
        await model.clearSelected()
        #expect(model.lines.map(\.line.text) == ["one"])
        #expect(await store.snapshot().map(\.line.text) == ["one"])
    }

    @Test("UI fallback mutates the shared capture policy")
    func policyFallback() async {
        let policy = CommunicationPolicyStore()
        let model = ChatModel(store: ChatStore(), policy: policy)
        await model.start()
        await model.setCapture(false, source: .nonChannel(.warfare))
        #expect(!policy.snapshot().captures(.nonChannel(.warfare)))
    }

    @Test("a restore racing panel startup hydrates the full bounded history")
    func atomicRestoreHydration() async throws {
        let store = ChatStore(maxLines: 10000)
        let model = ChatModel(store: store, maxLines: 10000)
        await model.start()
        let rows = (0..<10050).map { index in
            ChatLine(
                id: 0,
                timestamp: Date(timeIntervalSince1970: Double(index)),
                channel: index.isMultiple(of: 2) ? "clantalk" : "tell",
                player: "Player",
                line: Line(id: LineID(0), text: "history-\(index)")
            )
        }

        await store.restoreBatch(rows)
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.lines.count == 10000)
        #expect(model.lines.first?.line.text == "history-50")
        #expect(model.lines.last?.line.text == "history-10049")
        #expect(model.channels == ["clantalk", "tell"])
    }
}
