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

/// One captured chat line: the channel, the styled message, and a stable id.
public struct ChatLine: Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let timestamp: Date
    public let channel: String
    public let player: String
    /// The message parsed into styled text (Aardwolf `@`-codes resolved).
    public let line: Line

    public init(id: UInt64, timestamp: Date, channel: String, player: String, line: Line) {
        self.id = id
        self.timestamp = timestamp
        self.channel = channel
        self.player = player
        self.line = line
    }
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
    private var subscribers: [UUID: AsyncStream<ChatLine>.Continuation] = [:]

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
        let id = nextID
        nextID += 1
        let chatLine = ChatLine(
            id: id,
            timestamp: Date(),
            channel: channel,
            player: player,
            // Linkify here so channel lines are clickable in the Chat window —
            // they arrive via comm.channel GMCP and never pass the output
            // pipeline's URLLinkify plugin (live report: chat URLs dead).
            line: URLLinkifier.linkify(AardwolfColor.styledLine(from: message, id: LineID(id)))
        )
        lines.append(chatLine)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        for continuation in subscribers.values {
            continuation.yield(chatLine)
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
        timestamp: Date, channel: String, player: String, line: Line
    ) -> ChatLine {
        let id = nextID
        nextID += 1
        let chatLine = ChatLine(
            id: id, timestamp: timestamp, channel: channel, player: player, line: line
        )
        lines.append(chatLine)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        for continuation in subscribers.values {
            continuation.yield(chatLine)
        }
        return chatLine
    }

    /// Re-seed many previously-persisted lines in a single actor hop (session
    /// resume, #57) — like ``restore`` but for the whole backlog at once, so
    /// subscribers receive it as one rapid burst the UI can coalesce into a
    /// single update rather than a per-line trickle. Each row's `id` is
    /// ignored (fresh monotonic ids are assigned, as in ``restore``); its
    /// timestamp/channel/player/line are kept. Call **before**
    /// ``ChatPersistence`` attaches.
    public func restoreBatch(_ rows: [ChatLine]) {
        for row in rows {
            _ = restore(
                timestamp: row.timestamp, channel: row.channel, player: row.player, line: row.line
            )
        }
    }

    /// All distinct channel names seen so far, sorted.
    public func channels() -> [String] {
        Set(lines.map(\.channel)).sorted()
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

    /// Clear the log (e.g. on a fresh connection).
    public func reset() {
        lines.removeAll()
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
