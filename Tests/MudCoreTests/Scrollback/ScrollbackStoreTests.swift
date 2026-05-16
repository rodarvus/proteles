@testable import MudCore
import Testing

@Suite("ScrollbackStore — append & identifiers")
struct ScrollbackStoreAppendTests {
    @Test("Append assigns monotonic IDs starting at 0")
    func appendAssignsMonotonicIDs() async {
        let store = ScrollbackStore()
        let id0 = await store.append(text: "a")
        let id1 = await store.append(text: "b")
        let id2 = await store.append(text: "c")
        #expect(id0 == LineID(0))
        #expect(id1 == LineID(1))
        #expect(id2 == LineID(2))
    }

    @Test("Append(Line) overrides incoming id with the next monotonic id")
    func appendLineOverridesID() async {
        let store = ScrollbackStore()
        // Caller passes any placeholder; the store will renumber.
        let id = await store.append(
            Line(id: LineID(999), text: "x")
        )
        #expect(id == LineID(0))
        let lines = await store.snapshot()
        #expect(lines.first?.id == LineID(0))
    }

    @Test("totalAppended counts every append, including evicted")
    func totalAppendedCountsEvicted() async {
        let store = ScrollbackStore(maxLines: 2)
        for index in 0..<10 {
            await store.append(text: "\(index)")
        }
        let total = await store.totalAppended
        let count = await store.count
        #expect(total == 10)
        #expect(count == 2)
    }
}

@Suite("ScrollbackStore — eviction")
struct ScrollbackStoreEvictionTests {
    @Test("Eviction at maxLines keeps the newest lines")
    func evictionKeepsNewest() async {
        let store = ScrollbackStore(maxLines: 3)
        for index in 0..<5 {
            await store.append(text: "\(index)")
        }
        let lines = await store.snapshot()
        #expect(lines.map(\.text) == ["2", "3", "4"])
    }

    @Test("Eviction preserves monotonic IDs")
    func evictionPreservesIDs() async {
        let store = ScrollbackStore(maxLines: 2)
        for index in 0..<5 {
            await store.append(text: "\(index)")
        }
        let lines = await store.snapshot()
        // IDs 3 and 4 should remain; IDs 0–2 were evicted.
        #expect(lines.map(\.id) == [LineID(3), LineID(4)])
    }
}

@Suite("ScrollbackStore — snapshot")
struct ScrollbackStoreSnapshotTests {
    @Test("snapshot() returns lines in append order")
    func snapshotInAppendOrder() async {
        let store = ScrollbackStore()
        await store.append(text: "alpha")
        await store.append(text: "beta")
        await store.append(text: "gamma")
        let lines = await store.snapshot()
        #expect(lines.map(\.text) == ["alpha", "beta", "gamma"])
    }

    @Test("snapshot(in:) returns lines whose IDs fall in the range")
    func snapshotByRange() async {
        let store = ScrollbackStore()
        for index in 0..<10 {
            await store.append(text: "line-\(index)")
        }
        let lines = await store.snapshot(in: LineID(3)...LineID(5))
        #expect(lines.map(\.text) == ["line-3", "line-4", "line-5"])
    }

    @Test("snapshot(in:) skips evicted IDs")
    func snapshotByRangeSkipsEvicted() async {
        let store = ScrollbackStore(maxLines: 3)
        for index in 0..<5 {
            await store.append(text: "\(index)")
        }
        // Only IDs 2, 3, 4 are resident.
        let lines = await store.snapshot(in: LineID(0)...LineID(4))
        #expect(lines.map(\.id) == [LineID(2), LineID(3), LineID(4)])
    }
}

@Suite("ScrollbackStore — subscribers")
struct ScrollbackStoreSubscriberTests {
    @Test("Subscribers receive lines appended after subscribe()")
    func subscribersReceiveAppends() async {
        let store = ScrollbackStore()
        let stream = await store.subscribe()

        Task {
            await store.append(text: "first")
            await store.append(text: "second")
        }

        var received: [String] = []
        for await line in stream {
            received.append(line.text)
            if received.count == 2 { break }
        }
        #expect(received == ["first", "second"])
    }

    @Test("Multiple subscribers each receive every line")
    func multipleSubscribers() async {
        let store = ScrollbackStore()
        let stream1 = await store.subscribe()
        let stream2 = await store.subscribe()

        Task {
            await store.append(text: "x")
            await store.append(text: "y")
        }

        async let firstTask = Task {
            var collected: [String] = []
            for await line in stream1 {
                collected.append(line.text)
                if collected.count == 2 { break }
            }
            return collected
        }.value
        async let secondTask = Task {
            var collected: [String] = []
            for await line in stream2 {
                collected.append(line.text)
                if collected.count == 2 { break }
            }
            return collected
        }.value

        let (first, second) = await (firstTask, secondTask)
        #expect(first == ["x", "y"])
        #expect(second == ["x", "y"])
    }
}
