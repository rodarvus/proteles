#if os(macOS)
    import Foundation
    import MudCore

    /// Thread-safe FIFO between the off-main store subscription and the
    /// main-actor frame flush. A burst drains as one render transaction.
    final class EventInbox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ScrollbackEvent] = []

        func push(_ event: ScrollbackEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func drain() -> [ScrollbackEvent] {
            lock.lock()
            defer { lock.unlock() }
            guard !events.isEmpty else { return [] }
            let drained = events
            events.removeAll(keepingCapacity: true)
            return drained
        }

        func clear() {
            lock.lock()
            events.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    }

    extension ScrollbackEvent {
        var isEviction: Bool {
            if case .evicted = self { return true }
            return false
        }
    }
#endif
