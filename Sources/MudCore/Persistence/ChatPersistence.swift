import Foundation
import Logging

/// Observable outcome of an explicit chat-history flush. Clean disconnect and
/// app termination record this in the session transcript, making durability
/// failures distinguishable from capture failures in live recordings.
public struct ChatPersistenceFlushResult: Sendable, Equatable {
    public let written: Int
    public let pending: Int
    public let errorDescription: String?

    public var summary: String {
        var value = "wrote=\(written) pending=\(pending)"
        if let errorDescription { value += " error=\(errorDescription)" }
        return value
    }
}

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
    private weak var attachedStore: ChatStore?
    private var lastAppliedMutation: UInt64 = 0
    private var drainWaiters: [DrainWaiter] = []
    private let logger = Logger(label: "\(MudCore.loggerLabel).chat-persistence")

    private struct DrainWaiter {
        let target: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    /// A one-second default bounds the abnormal-exit loss window without doing
    /// per-line SQLite work. A clean disconnect and app termination also call
    /// ``flushNow()`` explicitly.
    public init(
        database: ChatDatabase,
        flushInterval: Duration = .seconds(1)
    ) {
        self.database = database
        self.flushInterval = flushInterval
    }

    /// Begin persisting lines from `store`. Safe to call repeatedly — each
    /// call detaches any prior binding first.
    public func attach(to store: ChatStore) async {
        await detach()
        let subscription = await store.subscribeMutations()
        attachedStore = store
        lastAppliedMutation = subscription.checkpoint
        subscriptionTask = Task { [weak self] in
            for await event in subscription.stream {
                await self?.apply(event)
            }
        }
        let interval = flushInterval
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                _ = await self?.flushNow()
            }
        }
    }

    /// Stop persisting. Any buffered lines are flushed first.
    public func detach() async {
        await flushNow()
        subscriptionTask?.cancel()
        subscriptionTask = nil
        flushTask?.cancel()
        flushTask = nil
        attachedStore = nil
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
    @discardableResult
    public func flushNow() async -> ChatPersistenceFlushResult {
        if let attachedStore {
            let target = await attachedStore.mutationCheckpoint()
            await waitUntilApplied(target)
        }
        return flushPending()
    }

    // MARK: - Private

    private func enqueue(_ chatLine: ChatLine) {
        guard chatLine.shouldPersist else { return }
        do {
            try pendingWrites.append(PersistedChatLine(chatLine))
        } catch {
            logger.warning("failed to serialize ChatLine for persistence: \(error)")
        }
    }

    private func apply(_ mutation: ChatStoreMutation) {
        switch mutation {
        case .append(_, let line):
            enqueue(line)
        case .clear(_, let source):
            if let source {
                pendingWrites.removeAll {
                    $0.sourceKind == source.persistenceKind && $0.sourceName == source.name
                }
            } else {
                pendingWrites.removeAll(keepingCapacity: true)
            }
            do {
                try database.clear(source: source)
            } catch {
                logger.error("chat clear failed: \(error)")
            }
        }
        lastAppliedMutation = mutation.sequence
        resumeSatisfiedDrainWaiters()
    }

    private func waitUntilApplied(_ target: UInt64) async {
        guard lastAppliedMutation < target else { return }
        await withCheckedContinuation { continuation in
            if lastAppliedMutation >= target {
                continuation.resume()
            } else {
                drainWaiters.append(DrainWaiter(target: target, continuation: continuation))
            }
        }
    }

    private func resumeSatisfiedDrainWaiters() {
        let ready = drainWaiters.filter { $0.target <= lastAppliedMutation }
        drainWaiters.removeAll { $0.target <= lastAppliedMutation }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func flushPending() -> ChatPersistenceFlushResult {
        guard !pendingWrites.isEmpty else {
            return ChatPersistenceFlushResult(written: 0, pending: 0, errorDescription: nil)
        }
        let batch = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        do {
            try database.insertBatch(batch)
            return ChatPersistenceFlushResult(
                written: batch.count, pending: pendingWrites.count, errorDescription: nil
            )
        } catch {
            // Don't lose the batch on a transient failure — put it back and
            // retry on the next tick.
            pendingWrites.insert(contentsOf: batch, at: 0)
            logger.error("chat batch insert failed: \(error)")
            return ChatPersistenceFlushResult(
                written: 0,
                pending: pendingWrites.count,
                errorDescription: String(describing: error)
            )
        }
    }
}
