import Foundation
import MudCore
import Observation
import SwiftUI

/// `@Observable` bridge over ``ChatStore`` for the chat-capture window.
///
/// Seeds from the store's backlog, then streams new lines. It also maintains a
/// **render store** — a ``ScrollbackStore`` of the currently-filtered lines —
/// so the Channels panel can render through the same AppKit output view as the
/// main game window (true overlay scrollbar + sticky live-tail). The render
/// store is rebuilt on a filter/timestamp change (bump ``renderToken`` to
/// re-init the view) and appended to live as new lines arrive.
@MainActor
@Observable
public final class ChatModel {
    public private(set) var lines: [ChatLine] = []
    public private(set) var channels: [String] = []

    /// Selected channel filter; `nil` means "all channels". Set via ``setFilter``.
    public private(set) var selectedChannel: String?

    /// The filtered render target for ``MudOutputView``; re-created on rebuild.
    public private(set) var renderStore = ScrollbackStore(maxLines: 5000)
    /// Bumped on every rebuild so the view re-inits with the new store.
    public private(set) var renderToken = 0

    private let store: ChatStore
    private let maxLines: Int
    private var streamTask: Task<Void, Never>?
    private var showTimestamps = false
    private var timestampSeconds = false

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

    /// Backfill the backlog, render it, then stream + tail new lines.
    public func start() async {
        let stream = await store.subscribe()
        let backlog = await store.snapshot()
        lines = backlog
        channels = await store.channels()
        await rebuildRender()
        let lastBackfilledID = backlog.last?.id

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            for await line in stream {
                if let lastBackfilledID, line.id <= lastBackfilledID { continue }
                await self?.ingest(line)
            }
        }
    }

    /// Switch the channel filter (from a tab click) and rebuild the render view.
    public func setFilter(_ channel: String?) {
        guard channel != selectedChannel else { return }
        selectedChannel = channel
        Task { await rebuildRender() }
    }

    /// Update the timestamp prefix preference and rebuild.
    public func setTimestamps(show: Bool, seconds: Bool) {
        guard show != showTimestamps || seconds != timestampSeconds else { return }
        showTimestamps = show
        timestampSeconds = seconds
        Task { await rebuildRender() }
    }

    private func ingest(_ line: ChatLine) async {
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        if !channels.contains(line.channel) {
            channels = (channels + [line.channel]).sorted()
        }
        if selectedChannel == nil || line.channel == selectedChannel {
            await renderStore.append(rendered(line)) // live-tail into the view
        }
    }

    private func rebuildRender() async {
        let fresh = ScrollbackStore(maxLines: maxLines)
        await fresh.appendBatch(filteredLines.map(rendered))
        renderStore = fresh
        renderToken += 1
    }

    /// Build the line to render, optionally prefixed with a dim timestamp column
    /// (run ranges shifted past the prefix so colours stay aligned).
    private func rendered(_ chatLine: ChatLine) -> Line {
        guard showTimestamps else { return chatLine.line }
        let prefix = timestampString(chatLine.timestamp) + "  "
        let shift = prefix.utf16.count
        let dim = StyleAttributes(foreground: .brightNamed(.black))
        let prefixRun = StyledRun(utf16Range: 0..<shift, style: dim)
        let shifted = chatLine.line.runs.map { run in
            StyledRun(
                utf16Range: (run.utf16Range.lowerBound + shift)..<(run.utf16Range.upperBound + shift),
                style: run.style,
                link: run.link
            )
        }
        return Line(
            id: chatLine.line.id,
            timestamp: chatLine.timestamp,
            text: prefix + chatLine.line.text,
            runs: [prefixRun] + shifted
        )
    }

    /// Locale-aware time (OS 12/24h), optionally with seconds.
    private func timestampString(_ date: Date) -> String {
        let style = Date.FormatStyle.dateTime.hour().minute()
        return date.formatted(timestampSeconds ? style.second() : style)
    }
}
