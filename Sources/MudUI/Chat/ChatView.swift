import MudCore
import SwiftUI

/// The chat-capture window: clickable per-channel tabs over a scrolling, styled
/// log of `comm.channel` lines (ARCHITECTURE.md §8.5). Rendered to match the main game
/// output — the active theme's palette + background, sticky-to-bottom, with an
/// optional timestamp column.
public struct ChatView: View {
    @Bindable private var model: ChatModel
    private let onHealthSnapshot: ((TextViewHealthSnapshot) -> Void)?
    @AppStorage("themeID") private var themeID = Theme.default.id
    @AppStorage("themeRevision") private var themeRevision = 0
    @AppStorage("chat.timestamps") private var showTimestamps = false
    @AppStorage("chat.timestampSeconds") private var timestampSeconds = false
    /// 1 except in a translucent floating miniwindow (the chrome fades the
    /// content backgrounds with it; the chat text keeps full contrast).
    @Environment(\.panelBackgroundOpacity) private var panelBackgroundOpacity

    /// Inside a translucent miniwindow the chrome's material is the one
    /// backdrop — painting our theme fill on top of it COMPOUNDS opacity
    /// (live report, 2026-06-10). Drop the fill there; keep it when docked.
    private var fillOpacity: Double {
        panelBackgroundOpacity < 1 ? 0 : 1
    }

    public init(
        model: ChatModel,
        onHealthSnapshot: ((TextViewHealthSnapshot) -> Void)? = nil
    ) {
        self.model = model
        self.onHealthSnapshot = onHealthSnapshot
    }

    private var palette: ColorPalette {
        _ = themeRevision
        return Theme.with(id: themeID).palette
    }

    public var body: some View {
        VStack(spacing: 0) {
            channelTabs
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.start() }
    }

    // MARK: - Channel tabs (clickable, recency-ordered, horizontally scrollable)

    private var channelTabs: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    tab("All", source: nil, active: model.selectedSource == nil) {
                        model.select(nil)
                    }
                    ForEach(model.recentSources, id: \.self) { source in
                        tab(source.displayName, source: source, active: model.selectedSource == source) {
                            model.select(source)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .scrollIndicators(.never)
            settingsMenu
                .padding(.trailing, 6)
        }
        .background(.bar)
    }

    private func tab(
        _ label: String,
        source: CommunicationSource?,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                if let source, let count = model.unread[source], count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 4)
                        .background(.black.opacity(0.2), in: Capsule())
                }
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Show timestamps", isOn: $showTimestamps)
            Toggle("Include seconds", isOn: $timestampSeconds).disabled(!showTimestamps)
            Divider()
            Toggle("Echo channels in main output", isOn: Binding(
                get: { model.policy.echoChannels },
                set: { enabled in Task { await model.setChannelEcho(enabled) } }
            ))
            Menu("Capture non-channel information") {
                ForEach(NonChannelKind.allCases, id: \.self) { kind in
                    let source = CommunicationSource.nonChannel(kind)
                    Toggle(kind.displayName, isOn: captureBinding(for: source))
                }
            }
            Menu("Echo non-channel information") {
                ForEach(NonChannelKind.allCases.filter { $0 != .remoteSocials }, id: \.self) { kind in
                    let source = CommunicationSource.nonChannel(kind)
                    Toggle(kind.displayName, isOn: echoBinding(for: source))
                }
            }
            if let source = model.selectedSource {
                Toggle("Capture \(source.displayName)", isOn: captureBinding(for: source))
                if source.supportsEchoControl {
                    Toggle("Echo \(source.displayName) in main output", isOn: echoBinding(for: source))
                }
            }
            Divider()
            Button(model.selectedSource == nil ? "Clear visible lines" : "Clear this source") {
                Task { await model.clearSelected() }
            }
            Button("Clear all lines") { Task { await model.clearAll() } }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Channels settings")
    }

    private func captureBinding(for source: CommunicationSource) -> Binding<Bool> {
        Binding(
            get: { model.policy.captures(source) },
            set: { enabled in Task { await model.setCapture(enabled, source: source) } }
        )
    }

    private func echoBinding(for source: CommunicationSource) -> Binding<Bool> {
        Binding(
            get: { model.policy.echoes(source) },
            set: { enabled in Task { await model.setEcho(enabled, source: source) } }
        )
    }

    // MARK: - Chat log

    @ViewBuilder
    private var content: some View {
        if model.filteredLines.isEmpty {
            ContentUnavailableView(
                "No Chat Yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Channel and tell messages appear here once you're connected.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(palette.defaultBackground).opacity(fillOpacity))
        } else {
            chatList
        }
    }

    private var chatList: some View {
        chatLog
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(palette.defaultBackground).opacity(fillOpacity))
    }

    @ViewBuilder
    private var chatLog: some View {
        #if os(macOS)
            ChatLogView(
                lines: model.filteredLines,
                palette: palette,
                showTimestamps: showTimestamps,
                timestampSeconds: timestampSeconds,
                filterKey: model.selectedSource.map {
                    "\($0.persistenceKind):\($0.name)"
                } ?? "__all__",
                fillOpacity: fillOpacity,
                onHealthSnapshot: onHealthSnapshot
            )
        #else
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.filteredLines) { chatLine in
                            row(chatLine)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(chatLine.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlayScrollers()
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.filteredLines.count) { scrollToEnd(proxy) }
                .onChange(of: model.selectedSource) { scrollToEnd(proxy) }
            }
        #endif
    }

    private func row(_ chatLine: ChatLine) -> some View {
        let message = Text(chatLine.line.attributedText(palette: palette))
        let line = showTimestamps && chatLine.showsTimestamp
            ? Text("\(timestamp(chatLine.timestamp)) ").foregroundStyle(.secondary) + message
            : message
        return line
            // Two steps smaller than the main output, per UX feedback.
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = model.filteredLines.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    /// Locale-aware time (OS 12/24h), optionally with seconds.
    private func timestamp(_ date: Date) -> String {
        let style = Date.FormatStyle.dateTime.hour().minute()
        return date.formatted(timestampSeconds ? style.second() : style)
    }
}

private extension CommunicationSource {
    var supportsEchoControl: Bool {
        switch self {
        case .channel: true
        case .nonChannel(.remoteSocials): false
        case .nonChannel: true
        case .plugin: false
        }
    }
}
