import Foundation
import Logging

/// Subscribes to a ``ScrollbackStore`` and persists every appended line to a
/// flat JSONL ring (``ScrollbackSidecar``): every ``flushInterval`` (250 ms)
/// the pending lines append to the sidecar, dirtying one page per flush. This
/// is what session-resume (#42) reads back as its tail.
///
/// History (#66 → #65 follow-up): an earlier design ALSO indexed every line
/// into `scrollback.sqlite` (SQLite + FTS5) on a second, slower cadence — to
/// back a full-text scrollback search. That index caused severe write
/// amplification (the 2026-06-12 OS disk-writes exception: 2.15 GB dirtied in
/// 6.6 h, ~40× the content size, every tiny commit rewriting WAL + FTS term
/// trees) — and it had **no UI consumer**: find-in-scrollback (D-104)
/// searches the live `NSTextView`, and resume reads this sidecar, not the
/// index. So the whole SQLite layer was removed; only the lightweight sidecar
/// remains. (Match the reference clients — Mudlet/MUSHclient/iTerm2 keep a
/// bounded in-memory buffer and do not persist/index scrollback at all.)
///
/// Crash behaviour: a crash loses at most ``flushInterval`` of unflushed
/// content — the same window as before. There is no longer an index to
/// reconcile, so attach is just subscribe + flush-on-tick.
public actor ScrollbackPersistence {
    public let flushInterval: Duration

    private let sidecar: ScrollbackSidecar
    private var pending: [Line] = []
    private var subscriptionTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private let logger = Logger(label: "\(MudCore.loggerLabel).persistence")

    /// The sidecar is constructed here so the non-Sendable file handle never
    /// crosses the actor boundary.
    public init(
        sidecarURL: URL,
        sidecarTargetLines: Int = 1000,
        flushInterval: Duration = .milliseconds(250)
    ) {
        sidecar = ScrollbackSidecar(url: sidecarURL, targetLines: sidecarTargetLines)
        self.flushInterval = flushInterval
    }

    /// Begin persisting lines from `store`. Safe to call repeatedly — each
    /// call detaches any prior binding first.
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
                await self?.flush()
            }
        }
    }

    /// Stop persisting. Everything buffered lands, so a graceful shutdown
    /// loses nothing.
    public func detach() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        flushTask?.cancel()
        flushTask = nil
        flush()
    }

    /// The most recent `limit` persisted lines, oldest-first, as ``Line``s —
    /// for restoring the on-screen scrollback after an update relaunch (#42).
    /// Read-only — seed the result into the store *before* attaching.
    public func loadTail(limit: Int) -> [Line] {
        sidecar.tail(limit: limit).compactMap { try? $0.toLine() }
    }

    /// Force everything buffered to disk now (graceful-shutdown path: app
    /// termination, tests).
    public func flushNow() {
        flush()
    }

    // MARK: - Private

    private func enqueue(_ line: Line) {
        pending.append(line)
    }

    /// Append the buffered lines to the sidecar (one page dirtied). On
    /// failure the batch is re-buffered so the next tick retries it.
    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        do {
            _ = try sidecar.append(batch)
        } catch {
            pending.insert(contentsOf: batch, at: 0)
            logger.error("sidecar append failed: \(error)")
        }
    }
}
