import MudCore
import Observation
import SwiftUI

/// `@Observable` bridge over ``ChatStore`` for the chat-capture window.
///
/// Seeds from the store's backlog, then streams new lines. Tracks the set
/// of channels seen and the user's channel filter. Same bridging pattern
/// as ``WorldsModel`` over `ProfileStore`.
@MainActor
@Observable
public final class ChatModel {
    public private(set) var lines: [ChatLine] = []
    public private(set) var channels: [String] = []

    /// Selected channel filter; `nil` means "all channels".
    public var selectedChannel: String?

    private let store: ChatStore
    private let maxLines: Int
    private var streamTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    /// Thread-safe intake buffer (same idea as the main output's render
    /// coalescing, D-01). The store subscription pushes here OFF the main actor
    /// and a main-actor drain loop applies the buffered lines in batches — so a
    /// burst (a resume backlog restored via ``ChatStore/restoreBatch(_:)``, or
    /// heavy channel spam) lands in one `lines` mutation (one SwiftUI update)
    /// instead of one update per line. The off-main subscription is essential:
    /// a main-isolated `for await` interleaves with everything else on the main
    /// actor and delivers one line per turn — the line-by-line resume trickle
    /// (#57 follow-up to the #42/#65 fixes).
    private let inbox = ChatLineInbox()

    public init(store: ChatStore, maxLines: Int = 5000) {
        self.store = store
        self.maxLines = maxLines
    }

    /// Lines matching the current filter.
    public var filteredLines: [ChatLine] {
        guard let selectedChannel else { return lines }
        return lines.filter { $0.channel == selectedChannel }
    }

    /// Channels ordered by most-recent activity (newest first) for the tab strip.
    public var recentChannels: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for line in lines.reversed() where !line.channel.isEmpty {
            if seen.insert(line.channel).inserted { result.append(line.channel) }
        }
        return result
    }

    /// Begin mirroring the store: backfill the backlog, then append new
    /// lines as they arrive. Safe to call from `.task`.
    public func start() async {
        // Subscribe before snapshotting so nothing slips through the gap;
        // dedupe the overlap by id.
        let stream = await store.subscribe()
        let backlog = await store.snapshot()
        lines = backlog
        channels = await store.channels()
        let lastBackfilledID = backlog.last?.id

        streamTask?.cancel()
        drainTask?.cancel()
        inbox.clear()
        // Drain the stream OFF the main actor into the inbox (Task.detached) —
        // a plain `Task {}` would inherit this @MainActor method's isolation
        // and run the `for await` on the main actor, one line per turn.
        let inbox = inbox
        streamTask = Task.detached {
            for await line in stream {
                if let lastBackfilledID, line.id <= lastBackfilledID { continue }
                inbox.push(line)
            }
        }
        // Apply buffered lines in batches on the main actor (one SwiftUI update
        // per drain), the way the main output's frame ticker drains its inbox.
        drainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.drainInbox()
            }
        }
    }

    /// Apply everything buffered since the last drain in one `lines` mutation.
    private func drainInbox() {
        let batch = inbox.drain()
        guard !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        let fresh = batch.map(\.channel).filter { !channels.contains($0) }
        if !fresh.isEmpty {
            channels = Array(Set(channels + fresh)).sorted()
        }
    }
}

/// Thread-safe FIFO of chat lines: pushed by the off-main store subscription,
/// drained by ``ChatModel``'s main-actor loop. Decoupling intake from the main
/// actor is what lets a restored backlog land as one batch (see ``ChatModel``).
private final class ChatLineInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [ChatLine] = []

    func push(_ line: ChatLine) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func drain() -> [ChatLine] {
        lock.lock()
        defer { lock.unlock() }
        guard !lines.isEmpty else { return [] }
        let drained = lines
        lines.removeAll(keepingCapacity: true)
        return drained
    }

    func clear() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
