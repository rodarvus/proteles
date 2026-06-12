import Foundation
import Logging

/// Subscribes to a ``ScrollbackStore`` and persists every appended line —
/// since #66 along **two paths with different cadences**:
///
/// - **Hot (crash safety)**: every ``flushInterval`` (250 ms) the pending
///   lines append to the ``ScrollbackSidecar`` — a flat JSONL ring whose
///   appends dirty one page per flush. This is what the resume tail reads.
/// - **Cold (search index)**: every ``indexInterval`` (60 s), and on
///   ``detach()``/``flushNow()``, the accumulated lines land in
///   `scrollback.sqlite` in ONE transaction that also advances the
///   `indexed_seq` cursor atomically.
///
/// Why: the old design committed an indexed SQLite row batch 4×/second —
/// each tiny transaction rewrote WAL pages for the row b-tree and the FTS5
/// term trees, ~40× write amplification (the 2026-06-12 OS disk-writes
/// exception: 2.15 GB dirtied in 6.6 h). Large infrequent transactions
/// amortise those index pages; the sidecar keeps per-line durability.
///
/// Crash recovery: ``attach(to:)`` first reconciles — sidecar entries with
/// `seq` beyond the database's cursor are indexed before new lines flow. A
/// crash therefore loses at most ``flushInterval`` of content (same as the
/// old design) and zero *indexed* content; at most one torn batch is
/// re-indexed as duplicates (cursor advances atomically with the rows).
public actor ScrollbackPersistence {
    public let database: ScrollbackDatabase
    public let flushInterval: Duration
    public let indexInterval: Duration

    private let sidecar: ScrollbackSidecar?
    private var pendingSidecar: [Line] = []
    private var pendingIndex: [(seq: UInt64, line: PersistedLine)] = []
    private var subscriptionTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private let logger = Logger(label: "\(MudCore.loggerLabel).persistence")

    /// `sidecarURL: nil` falls back to indexing on the hot cadence (the old
    /// behaviour) — used only by tests that exercise the database directly.
    /// The sidecar is constructed here so the non-Sendable file handle never
    /// crosses the actor boundary.
    public init(
        database: ScrollbackDatabase,
        sidecarURL: URL? = nil,
        sidecarTargetLines: Int = 1000,
        flushInterval: Duration = .milliseconds(250),
        indexInterval: Duration = .seconds(60)
    ) {
        self.database = database
        sidecar = sidecarURL.map { ScrollbackSidecar(url: $0, targetLines: sidecarTargetLines) }
        self.flushInterval = flushInterval
        self.indexInterval = indexInterval
    }

    /// Begin persisting lines from `store`. Reconciles the sidecar into the
    /// index first (crash recovery), then subscribes. Safe to call
    /// repeatedly — each call detaches any prior binding first.
    public func attach(to store: ScrollbackStore) async {
        detach()
        reconcileSidecar()
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
                await self?.flushHot()
            }
        }
        let indexEvery = indexInterval
        indexTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: indexEvery)
                await self?.flushIndex()
            }
        }
    }

    /// Stop persisting. Everything buffered lands (sidecar + index), so a
    /// graceful shutdown loses nothing.
    public func detach() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        flushTask?.cancel()
        flushTask = nil
        indexTask?.cancel()
        indexTask = nil
        flushHot()
        flushIndex()
    }

    /// Run a search against the underlying database. See
    /// ``ScrollbackDatabase/search(_:limit:)`` for query semantics. (The
    /// index may trail live output by up to ``indexInterval``.)
    public func search(_ query: String, limit: Int? = 200) throws -> [PersistedLine] {
        try database.search(query, limit: limit)
    }

    /// The most recent `limit` persisted lines, oldest-first, as ``Line``s —
    /// for restoring the on-screen scrollback after an update relaunch (#42).
    /// Reads the **sidecar** (the hot path, current to the last flush); falls
    /// back to the database for installs whose sidecar doesn't exist yet.
    /// Read-only — seed the result into the store *before* attaching.
    public func loadTail(limit: Int) throws -> [Line] {
        if let sidecar {
            let entries = sidecar.tail(limit: limit)
            if !entries.isEmpty {
                return entries.compactMap { try? $0.toLine() }
            }
        }
        return try database.mostRecent(limit: limit).compactMap { try? $0.toLine() }
    }

    /// Force everything to disk now — sidecar AND index (graceful-shutdown
    /// path: app termination, tests, user-driven saves).
    public func flushNow() {
        flushHot()
        flushIndex()
    }

    // MARK: - Private

    private func enqueue(_ line: Line) {
        pendingSidecar.append(line)
    }

    /// Hot path: pending lines → sidecar append (one page dirtied), then
    /// queue them for the cold index. Without a sidecar they go straight to
    /// the index queue.
    private func flushHot() {
        guard !pendingSidecar.isEmpty else { return }
        let batch = pendingSidecar
        pendingSidecar.removeAll(keepingCapacity: true)
        guard let sidecar else {
            queueForIndex(batch.map { (UInt64.max, $0) })
            flushIndex() // legacy mode: index on the hot cadence
            return
        }
        do {
            let entries = try sidecar.append(batch)
            queueForIndex(zip(entries, batch).map { ($0.seq, $1) })
        } catch {
            // Don't lose the batch — retry on the next tick.
            pendingSidecar.insert(contentsOf: batch, at: 0)
            logger.error("sidecar append failed: \(error)")
        }
    }

    private func queueForIndex(_ batch: [(UInt64, Line)]) {
        for (seq, line) in batch {
            do {
                try pendingIndex.append((seq: seq, line: PersistedLine(line)))
            } catch {
                logger.warning("failed to serialize Line for persistence: \(error)")
            }
        }
    }

    /// Cold path: one big transaction for everything since the last index
    /// flush, advancing the cursor atomically with the rows.
    private func flushIndex() {
        guard !pendingIndex.isEmpty else { return }
        let batch = pendingIndex
        pendingIndex.removeAll(keepingCapacity: true)
        let maxSeq = batch.map(\.seq).max() ?? 0
        do {
            if maxSeq == UInt64.max { // legacy (sidecar-less) mode
                try database.insertBatch(batch.map(\.line))
            } else {
                try database.insertSidecarBatch(batch.map(\.line), through: maxSeq)
            }
        } catch {
            pendingIndex.insert(contentsOf: batch, at: 0)
            logger.error("scrollback index batch failed: \(error)")
        }
    }

    /// Launch reconciliation: index whatever the sidecar holds beyond the
    /// database's cursor (the lines a crash left flushed-but-unindexed).
    private func reconcileSidecar() {
        guard let sidecar else { return }
        do {
            let cursor = try database.indexedThroughSeq()
            let missing = sidecar.entries(after: cursor)
            guard !missing.isEmpty else { return }
            let lines = missing.map {
                PersistedLine(timestamp: $0.timestamp, text: $0.text, runsJSON: $0.runsJSON)
            }
            try database.insertSidecarBatch(lines, through: missing.last!.seq)
            logger.info("reconciled \(missing.count) sidecar line(s) into the index")
        } catch {
            logger.error("sidecar reconciliation failed: \(error)")
        }
    }
}
