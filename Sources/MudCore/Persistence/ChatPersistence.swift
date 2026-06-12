import Foundation
import Logging

/// Subscribes to a ``ChatStore`` and writes every captured chat line to a
/// ``ChatDatabase`` (#57) — ``ScrollbackPersistence``'s sibling, so the Chat
/// window's history survives crashes and update relaunches.
///
/// Same shape end to end: persist on append (crash-safe), batch the writes
/// (one transaction per ``flushInterval`` under bursty channel traffic), and
/// flush on ``detach()`` so a graceful shutdown loses nothing. Restores must
/// seed the store **before** ``attach(to:)`` — the subscription only sees
/// new appends, which is exactly what keeps a restored tail from being
/// written to the DB a second time.
public actor ChatPersistence {
    public let database: ChatDatabase
    public let flushInterval: Duration

    private var pendingWrites: [PersistedChatLine] = []
    private var subscriptionTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private let logger = Logger(label: "\(MudCore.loggerLabel).chat-persistence")

    /// 60 s default (#66): chat volume is tiny, but a 250 ms transaction
    /// cadence pays the same WAL+FTS write amplification per commit as
    /// scrollback did. The loss window on a hard crash is ≤ one interval of
    /// *chat-window* history (the lines still exist in the scrollback
    /// sidecar and the transcript); a graceful quit flushes everything via
    /// ``detach()``/``flushNow()``.
    public init(
        database: ChatDatabase,
        flushInterval: Duration = .seconds(60)
    ) {
        self.database = database
        self.flushInterval = flushInterval
    }

    /// Begin persisting lines from `store`. Safe to call repeatedly — each
    /// call detaches any prior binding first.
    public func attach(to store: ChatStore) async {
        detach()
        let stream = await store.subscribe()
        subscriptionTask = Task { [weak self] in
            for await chatLine in stream {
                await self?.enqueue(chatLine)
            }
        }
        let interval = flushInterval
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.flushPending()
            }
        }
    }

    /// Stop persisting. Any buffered lines are flushed first.
    public func detach() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        flushTask?.cancel()
        flushTask = nil
        flushPending()
    }

    /// Search the underlying database (see ``ChatDatabase/search(_:channel:limit:)``).
    public func search(
        _ query: String, channel: String? = nil, limit: Int? = 200
    ) throws -> [PersistedChatLine] {
        try database.search(query, channel: channel, limit: limit)
    }

    /// The most recent `limit` persisted chat lines, oldest-first — for
    /// restoring the Chat window after an update relaunch (the scrollback
    /// resume's sibling). Read-only: seed the result into the store *before*
    /// attaching, or it would be persisted a second time.
    public func loadTail(limit: Int) throws -> [PersistedChatLine] {
        try database.mostRecent(limit: limit)
    }

    /// Force a flush now (tests + user-driven saves).
    public func flushNow() {
        flushPending()
    }

    // MARK: - Private

    private func enqueue(_ chatLine: ChatLine) {
        do {
            try pendingWrites.append(PersistedChatLine(chatLine))
        } catch {
            logger.warning("failed to serialize ChatLine for persistence: \(error)")
        }
    }

    private func flushPending() {
        guard !pendingWrites.isEmpty else { return }
        let batch = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        do {
            try database.insertBatch(batch)
        } catch {
            // Don't lose the batch on a transient failure — put it back and
            // retry on the next tick.
            pendingWrites.insert(contentsOf: batch, at: 0)
            logger.error("chat batch insert failed: \(error)")
        }
    }
}
