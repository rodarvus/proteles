import Foundation

/// `Comm.Channel` GMCP payload — one channel/chat/tell line (ARCHITECTURE.md §5.5).
/// `msg` carries Aardwolf `@`-colour codes (see ``AardwolfColor``).
public struct CommChannel: Codable, Sendable, Equatable {
    public let chan: String
    public let msg: String
    public let player: String

    public init(chan: String, msg: String, player: String = "") {
        self.chan = chan
        self.msg = msg
        self.player = player
    }
}

/// One captured Channels-panel line and its typed origin.
public struct ChatLine: Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let timestamp: Date
    public let source: CommunicationSource
    public let player: String
    public let showsTimestamp: Bool
    /// Runtime-only persistence admission (`storeFromOutside(..., omit_log)`).
    public let shouldPersist: Bool
    /// The message parsed into styled text (Aardwolf `@`-codes resolved).
    public let line: Line

    public init(
        id: UInt64,
        timestamp: Date,
        source: CommunicationSource,
        player: String,
        line: Line,
        showsTimestamp: Bool = true,
        shouldPersist: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.player = player
        self.line = line
        self.showsTimestamp = showsTimestamp
        self.shouldPersist = shouldPersist
    }

    /// Compatibility for existing channel-only call sites and stored fixtures.
    public init(id: UInt64, timestamp: Date, channel: String, player: String, line: Line) {
        self.init(
            id: id, timestamp: timestamp, source: .channel(channel), player: player, line: line
        )
    }

    public var channel: String {
        source.name
    }
}

/// Ordered mutations consumed by persistence. Keeping clears on the same
/// stream as appends prevents a pre-clear line from being written back later
/// by the persistence actor's batching delay.
public enum ChatStoreMutation: Sendable, Equatable {
    case append(sequence: UInt64, line: ChatLine)
    case clear(sequence: UInt64, source: CommunicationSource?)

    public var sequence: UInt64 {
        switch self {
        case .append(let sequence, _), .clear(let sequence, _): sequence
        }
    }
}

/// UI-facing events preserve live single-line delivery while making a restored
/// history an atomic batch. This avoids thousands of main-actor updates when
/// the Channels panel starts before launch hydration finishes.
public enum ChatStoreEvent: Sendable, Equatable {
    case append(ChatLine)
    case restoreBatch([ChatLine])
}

/// Captures `comm.channel` GMCP messages into a bounded, observable chat
/// log — the backing store for the chat-capture window.
///
/// Same actor + `subscribe()` shape as ``ScrollbackStore``: the UI takes a
/// ``snapshot()`` for backfill, then streams new lines.
public actor ChatStore {
    public private(set) var lines: [ChatLine] = []
    public let maxLines: Int

    private var nextID: UInt64 = 0
    private var mutationSequence: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<ChatLine>.Continuation] = [:]
    private var eventSubscribers: [UUID: AsyncStream<ChatStoreEvent>.Continuation] = [:]
    private var mutationSubscribers: [UUID: AsyncStream<ChatStoreMutation>.Continuation] = [:]

    public init(maxLines: Int = 5000) {
        self.maxLines = max(maxLines, 1)
    }

    /// Decode and store a `comm.channel` message. Returns the appended
    /// line, or `nil` if `message` isn't a comm.channel or didn't decode.
    @discardableResult
    public func ingest(_ message: GMCPMessage) -> ChatLine? {
        guard message.package.lowercased() == "comm.channel" else { return nil }
        guard let comm = try? message.decode(CommChannel.self) else { return nil }
        return append(channel: comm.chan, player: comm.player, message: comm.msg)
    }

    /// Append a chat line built from a raw `@`-coded message.
    @discardableResult
    public func append(channel: String, player: String, message: String) -> ChatLine {
        append(source: .channel(channel), player: player, message: message)
    }

    /// Append an Aard-coded line from any typed communication source.
    @discardableResult
    public func append(
        source: CommunicationSource,
        player: String = "",
        message: String,
        showsTimestamp: Bool = true,
        shouldPersist: Bool = true
    ) -> ChatLine {
        append(
            source: source,
            player: player,
            line: AardwolfColor.styledLine(from: message),
            showsTimestamp: showsTimestamp,
            shouldPersist: shouldPersist
        )
    }

    /// Append a pre-styled line (used after text substitution and by plugins).
    @discardableResult
    public func append(
        source: CommunicationSource,
        player: String = "",
        line: Line,
        showsTimestamp: Bool = true,
        shouldPersist: Bool = true
    ) -> ChatLine {
        let id = nextID
        nextID += 1
        let chatLine = ChatLine(
            id: id,
            timestamp: Date(),
            source: source,
            player: player,
            // Linkify here so channel lines are clickable in the Chat window —
            // they arrive via comm.channel GMCP and never pass the output
            // pipeline's URLLinkify plugin (live report: chat URLs dead).
            line: URLLinkifier.linkify(Line(
                id: LineID(id), timestamp: line.timestamp, text: line.text, runs: line.runs
            )),
            showsTimestamp: showsTimestamp,
            shouldPersist: shouldPersist
        )
        lines.append(chatLine)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        for continuation in subscribers.values {
            continuation.yield(chatLine)
        }
        for continuation in eventSubscribers.values {
            continuation.yield(.append(chatLine))
        }
        if !mutationSubscribers.isEmpty {
            mutationSequence &+= 1
            for continuation in mutationSubscribers.values {
                continuation.yield(.append(sequence: mutationSequence, line: chatLine))
            }
        }
        return chatLine
    }

    /// Re-seed one previously-persisted line (session resume, #57): the
    /// styled `line` is stored as-is — no `@`-code re-parse — under a fresh
    /// monotonic id, preserving its original timestamp. Subscribers are
    /// notified like any append. Call this **before** ``ChatPersistence``
    /// attaches, or the restored backlog would be written to disk again.
    @discardableResult
    public func restore(
        timestamp: Date,
        source: CommunicationSource,
        player: String,
        line: Line,
        showsTimestamp: Bool = true
    ) -> ChatLine {
        let id = nextID
        nextID += 1
        let chatLine = ChatLine(
            id: id,
            timestamp: timestamp,
            source: source,
            player: player,
            line: line,
            showsTimestamp: showsTimestamp
        )
        lines.append(chatLine)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        for continuation in subscribers.values {
            continuation.yield(chatLine)
        }
        for continuation in eventSubscribers.values {
            continuation.yield(.restoreBatch([chatLine]))
        }
        return chatLine
    }

    /// Compatibility overload for channel-only restore callers.
    @discardableResult
    public func restore(
        timestamp: Date, channel: String, player: String, line: Line
    ) -> ChatLine {
        restore(timestamp: timestamp, source: .channel(channel), player: player, line: line)
    }

    /// Re-seed many previously-persisted lines in a single actor hop (session
    /// resume, #57) — like ``restore`` but for the whole backlog at once, so
    /// subscribers receive it as one rapid burst the UI can coalesce into a
    /// single update rather than a per-line trickle. Each row's `id` is
    /// ignored (fresh monotonic ids are assigned, as in ``restore``); its
    /// timestamp/channel/player/line are kept. Call **before**
    /// ``ChatPersistence`` attaches.
    public func restoreBatch(_ rows: [ChatLine]) {
        guard !rows.isEmpty else { return }
        var restored: [ChatLine] = []
        restored.reserveCapacity(rows.count)
        for row in rows {
            let id = nextID
            nextID += 1
            restored.append(ChatLine(
                id: id,
                timestamp: row.timestamp,
                source: row.source,
                player: row.player,
                line: row.line,
                showsTimestamp: row.showsTimestamp
            ))
        }
        lines.append(contentsOf: restored)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        for line in restored {
            for continuation in subscribers.values {
                continuation.yield(line)
            }
        }
        for continuation in eventSubscribers.values {
            continuation.yield(.restoreBatch(restored))
        }
    }

    /// All distinct channel names seen so far, sorted.
    public func channels() -> [String] {
        Set(lines.compactMap { line in
            guard case .channel(let channel) = line.source else { return nil }
            return channel
        }).sorted()
    }

    /// All distinct typed sources, newest activity first.
    public func sources() -> [CommunicationSource] {
        var seen: Set<CommunicationSource> = []
        return lines.reversed().compactMap { seen.insert($0.source).inserted ? $0.source : nil }
    }

    /// Current backlog, oldest first.
    public func snapshot() -> [ChatLine] {
        lines
    }

    /// Subscribe to newly-appended chat lines (no backfill). Cancel
    /// iteration to unsubscribe.
    public func subscribe() -> AsyncStream<ChatLine> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChatLine>.makeStream(
            bufferingPolicy: .unbounded
        )
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Subscribe to live appends and atomic restore batches (no backfill).
    /// The Channels model uses this stream so launch history restoration is
    /// applied in one main-actor update even if hydration races panel startup.
    public func subscribeEvents() -> AsyncStream<ChatStoreEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChatStoreEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        eventSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return stream
    }

    /// Subscribe to ordered append/clear mutations (no backfill). Persistence
    /// uses this instead of the line-only UI stream.
    public func subscribeMutations() -> (
        stream: AsyncStream<ChatStoreMutation>, checkpoint: UInt64
    ) {
        let id = UUID()
        let pair = AsyncStream<ChatStoreMutation>.makeStream(bufferingPolicy: .unbounded)
        mutationSubscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeMutationSubscriber(id) }
        }
        return (pair.stream, mutationSequence)
    }

    /// Highest mutation token published so far. A persistence flush waits
    /// until it has consumed this token before writing its pending batch.
    public func mutationCheckpoint() -> UInt64 {
        mutationSequence
    }

    /// Clear the log (e.g. on a fresh connection).
    public func reset() {
        lines.removeAll()
    }

    public func clear(source: CommunicationSource?) {
        if let source {
            lines.removeAll { $0.source == source }
        } else {
            lines.removeAll()
        }
        if !mutationSubscribers.isEmpty {
            mutationSequence &+= 1
            for continuation in mutationSubscribers.values {
                continuation.yield(.clear(sequence: mutationSequence, source: source))
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventSubscribers[id] = nil
    }

    private func removeMutationSubscriber(_ id: UUID) {
        mutationSubscribers[id] = nil
    }
}
