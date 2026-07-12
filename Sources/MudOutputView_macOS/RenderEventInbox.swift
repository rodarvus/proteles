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
        var evictionCount: Int {
            switch self {
            case .evicted: 1
            case .limitChanged(_, let evicted): evicted.count
            default: 0
            }
        }

        var requiresImmediateEvictionTrim: Bool {
            if case .limitChanged = self { return true }
            return false
        }
    }
#endif
