import MudCore
import SwiftUI

/// The chat-capture window: clickable per-channel tabs over a scrolling, styled
/// log of `comm.channel` lines (PLAN.md §8.5). Rendered to match the main game
/// output — the active theme's palette + background, sticky-to-bottom, with an
/// optional timestamp column.
public struct ChatView: View {
    @Bindable private var model: ChatModel
    @AppStorage("themeID") private var themeID = Theme.default.id
    @AppStorage("chat.timestamps") private var showTimestamps = false
    @AppStorage("chat.timestampSeconds") private var timestampSeconds = false

    public init(model: ChatModel) {
        self.model = model
    }

    private var palette: ColorPalette {
        Theme.with(id: themeID).palette
    }

    public var body: some View {
        VStack(spacing: 0) {
            channelTabs
            Divider()
            content
        }
        .task { await model.start() }
    }

    // MARK: - Channel tabs (clickable, recency-ordered, horizontally scrollable)

    private var channelTabs: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    tab("All", active: model.selectedChannel == nil) { model.selectedChannel = nil }
                    ForEach(model.recentChannels, id: \.self) { channel in
                        tab(channel, active: model.selectedChannel == channel) {
                            model.selectedChannel = channel
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .scrollIndicators(.never)
            timestampMenu
                .padding(.trailing, 6)
        }
        .background(.bar)
    }

    private func tab(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
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

    private var timestampMenu: some View {
        Menu {
            Toggle("Show timestamps", isOn: $showTimestamps)
            Toggle("Include seconds", isOn: $timestampSeconds).disabled(!showTimestamps)
        } label: {
            Image(systemName: "clock").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Timestamp display")
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
            .background(Color(palette.defaultBackground))
        } else {
            chatList
        }
    }

    private var chatList: some View {
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
            }
            // Match the main output: pin to the bottom (resists accidental drift)
            // and only show the scroller while scrolling.
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.automatic)
            .onChange(of: model.filteredLines.count) { scrollToEnd(proxy) }
            .onChange(of: model.selectedChannel) { scrollToEnd(proxy) }
        }
        .background(Color(palette.defaultBackground))
    }

    private func row(_ chatLine: ChatLine) -> some View {
        let message = Text(chatLine.line.attributedText(palette: palette))
        let line = showTimestamps
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
