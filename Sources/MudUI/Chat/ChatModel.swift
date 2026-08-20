import MudCore
import Observation
import SwiftUI

/// `@Observable` bridge over ``ChatStore`` for the chat-capture window.
///
/// Seeds from the store's backlog, then streams new lines. Tracks the set
/// of channels seen and the user's channel filter. Same bridging pattern
/// as ``WorldsModel`` over `ProfileStore`.
///
/// Live intake stays a direct main-actor append. Restored history arrives as an
/// explicit batch event from ``ChatStore``, so launch hydration takes one UI
/// update without delaying or coalescing subsequent live lines.
@MainActor
@Observable
public final class ChatModel {
    public private(set) var lines: [ChatLine] = []
    public private(set) var channels: [String] = []
    public private(set) var policy = CommunicationPolicySnapshot()
    public private(set) var unread: [CommunicationSource: Int] = [:]

    /// Selected typed source filter; `nil` means all communication.
    public private(set) var selectedSource: CommunicationSource?

    /// Compatibility for channel-only callers.
    public var selectedChannel: String? {
        get {
            guard case .channel(let name) = selectedSource else { return nil }
            return name
        }
        set { select(newValue.map(CommunicationSource.channel)) }
    }

    private let store: ChatStore
    private let policyStore: CommunicationPolicyStore
    private let onCommand: (@Sendable (String) async -> Void)?
    private let maxLines: Int
    private var streamTask: Task<Void, Never>?
    private var policyTask: Task<Void, Never>?

    public init(
        store: ChatStore,
        policy: CommunicationPolicyStore = CommunicationPolicyStore(),
        maxLines: Int = 5000,
        onCommand: (@Sendable (String) async -> Void)? = nil
    ) {
        self.store = store
        policyStore = policy
        self.maxLines = maxLines
        self.onCommand = onCommand
    }

    /// Lines matching the current filter.
    public var filteredLines: [ChatLine] {
        guard let selectedSource else { return lines }
        return lines.filter { $0.source == selectedSource }
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

    public var recentSources: [CommunicationSource] {
        var seen: Set<CommunicationSource> = []
        return lines.reversed().compactMap { seen.insert($0.source).inserted ? $0.source : nil }
    }

    public func select(_ source: CommunicationSource?) {
        selectedSource = source
        if let source { unread[source] = nil } else { unread.removeAll() }
    }

    public func setCapture(_ enabled: Bool, source: CommunicationSource) async {
        policyStore.setCapture(enabled, source: source)
        await persistPolicy()
    }

    public func setEcho(_ enabled: Bool, source: CommunicationSource) async {
        policyStore.setEcho(enabled, source: source)
        await persistPolicy()
    }

    public func setChannelEcho(_ enabled: Bool) async {
        policyStore.setEchoChannels(enabled)
        await persistPolicy()
    }

    public func clearSelected() async {
        let source = selectedSource
        await store.clear(source: source)
        if let source {
            lines.removeAll { $0.source == source }
            unread[source] = nil
        } else {
            lines.removeAll()
            unread.removeAll()
        }
        channels = await store.channels()
    }

    public func clearAll() async {
        await store.clear(source: nil)
        lines.removeAll()
        channels.removeAll()
        unread.removeAll()
        selectedSource = nil
    }

    /// Begin mirroring the store: backfill the backlog, then append new
    /// lines as they arrive. Safe to call from `.task`.
    public func start() async {
        // Subscribe before snapshotting so nothing slips through the gap;
        // dedupe the overlap by id.
        let stream = await store.subscribeEvents()
        let backlog = await store.snapshot()
        let policyStream = policyStore.subscribe()
        lines = backlog
        channels = await store.channels()
        policy = policyStore.snapshot()
        let lastBackfilledID = backlog.last?.id

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            for await event in stream {
                switch event {
                case .append(let line):
                    if let lastBackfilledID, line.id <= lastBackfilledID { continue }
                    self?.append(line)
                case .restoreBatch(let restored):
                    let newLines = restored.filter { line in
                        lastBackfilledID.map { line.id > $0 } ?? true
                    }
                    self?.appendBatch(newLines)
                }
            }
        }
        policyTask?.cancel()
        policyTask = Task { [weak self] in
            for await snapshot in policyStream {
                self?.policy = snapshot
            }
        }
    }

    private func append(_ line: ChatLine) {
        PerformanceProbe.shared.measure(
            "ui.chat-model.append",
            events: 1,
            thresholdMS: 50
        ) {
            lines.append(line)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            if !channels.contains(line.channel) {
                if case .channel(let channel) = line.source {
                    channels = (channels + [channel]).sorted()
                }
            }
            if selectedSource != nil, selectedSource != line.source {
                unread[line.source, default: 0] += 1
            }
        }
    }

    private func appendBatch(_ batch: [ChatLine]) {
        guard !batch.isEmpty else { return }
        PerformanceProbe.shared.measure(
            "ui.chat-model.restore-batch",
            events: batch.count,
            thresholdMS: 100
        ) {
            lines.append(contentsOf: batch)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            channels = Set(lines.compactMap { line in
                guard case .channel(let channel) = line.source else { return nil }
                return channel
            }).sorted()
            if let selectedSource {
                for line in batch where line.source != selectedSource {
                    unread[line.source, default: 0] += 1
                }
            }
        }
    }

    private func persistPolicy() async {
        await onCommand?("chats save")
    }
}
