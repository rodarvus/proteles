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

    /// Coalescing buffer for streamed lines (same idea as the main output's
    /// render coalescing, D-01). The store subscription appends here and
    /// schedules a single flush on the next main-actor turn, so a burst — a
    /// resume backlog restored via ``ChatStore/restoreBatch(_:)``, or heavy
    /// channel spam — lands in ONE `lines` mutation (one SwiftUI update)
    /// instead of one update per line. Without this the restored backlog
    /// filled the panel line-by-line (#57 follow-up to the #42/#65 fixes).
    private var pendingAppends: [ChatLine] = []
    private var appendFlushScheduled = false

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
        streamTask = Task { [weak self] in
            for await line in stream {
                if let lastBackfilledID, line.id <= lastBackfilledID { continue }
                self?.scheduleAppend(line)
            }
        }
    }

    /// Buffer a streamed line and schedule a single coalesced flush on the
    /// next main-actor turn (see ``pendingAppends``).
    private func scheduleAppend(_ line: ChatLine) {
        pendingAppends.append(line)
        guard !appendFlushScheduled else { return }
        appendFlushScheduled = true
        Task { @MainActor [weak self] in self?.flushAppends() }
    }

    /// Apply all buffered lines in one `lines` mutation.
    private func flushAppends() {
        appendFlushScheduled = false
        guard !pendingAppends.isEmpty else { return }
        let batch = pendingAppends
        pendingAppends.removeAll(keepingCapacity: true)
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
