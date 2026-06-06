import Foundation
import Logging

/// Subscribes to a ``ScrollbackStore`` and writes every appended line
/// to a ``ScrollbackDatabase`` (PLAN.md §6.5, §8.3).
///
/// Why every line (not only evicted ones): persisting on append is
/// crash-safe — if the app dies mid-session, the on-disk log already
/// has everything seen so far. Persisting only on eviction would lose
/// the most recent `maxLines` lines on a crash.
///
/// Writes are batched: appended lines accumulate in a buffer and the
/// batch is flushed to SQLite at most every ``flushInterval``. Under
/// Aardwolf's bursty traffic this collapses dozens of inserts into one
/// transaction without ever delaying a line by more than the interval.
public actor ScrollbackPersistence {
    public let database: ScrollbackDatabase
    public let flushInterval: Duration

    private var pendingWrites: [PersistedLine] = []
    private var subscriptionTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private let logger = Logger(label: "\(MudCore.loggerLabel).persistence")

    public init(
        database: ScrollbackDatabase,
        flushInterval: Duration = .milliseconds(250)
    ) {
        self.database = database
        self.flushInterval = flushInterval
    }

    /// Begin persisting lines from `store`. Safe to call repeatedly —
    /// each call detaches any prior binding first.
    public func attach(to store: ScrollbackStore) async {
        detach()
        let stream = await store.events()
        subscriptionTask = Task { [weak self] in
            for await event in stream {
                if case .appended(let line) = event {
                    await self?.enqueue(line)
                }
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

    /// Stop persisting. Any buffered lines are flushed first so a
    /// graceful shutdown loses nothing.
    public func detach() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        flushTask?.cancel()
        flushTask = nil
        flushPending()
    }

    /// Run a search against the underlying database. See
    /// ``ScrollbackDatabase/search(_:limit:)`` for query semantics.
    public func search(_ query: String, limit: Int? = 200) throws -> [PersistedLine] {
        try database.search(query, limit: limit)
    }

    /// The most recent `limit` persisted lines, oldest-first, as ``Line``s —
    /// for restoring the on-screen scrollback after an update relaunch (#42,
    /// Phase 2a "session resume"). Read-only: it neither touches the live buffer
    /// nor re-persists anything (the caller must seed these into the view
    /// *without* re-appending them to a persistence-attached store, or they'd be
    /// written to the DB a second time). A line that fails to decode is skipped.
    public func loadTail(limit: Int) throws -> [Line] {
        try database.mostRecent(limit: limit).compactMap { try? $0.toLine() }
    }

    /// Force a flush now. Useful in tests and on user-driven save
    /// actions; the periodic ticker calls this every ``flushInterval``.
    public func flushNow() {
        flushPending()
    }

    // MARK: - Private

    private func enqueue(_ line: Line) {
        do {
            try pendingWrites.append(PersistedLine(line))
        } catch {
            logger.warning(
                "failed to serialize Line for persistence: \(error)"
            )
        }
    }

    private func flushPending() {
        guard !pendingWrites.isEmpty else { return }
        let batch = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        do {
            try database.insertBatch(batch)
        } catch {
            // Don't lose the batch on a transient failure — put it
            // back at the front and retry on the next tick.
            pendingWrites.insert(contentsOf: batch, at: 0)
            logger.error(
                "scrollback batch insert failed: \(error)"
            )
        }
    }
}
