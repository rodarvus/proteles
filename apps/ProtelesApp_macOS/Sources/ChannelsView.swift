import MudCore
import MudOutputView_macOS
import MudUI
import SwiftUI

/// The **Channels** panel: clickable per-channel tabs over the captured chat,
/// rendered through the shared AppKit ``MudOutputView`` (same overlay scrollbar,
/// sticky live-tail, and theme palette as the main game window). The filtered
/// chat is mirrored into ``ChatModel/renderStore``; switching tabs rebuilds it
/// and re-inits the view (so it opens scrolled to the end).
struct ChannelsView: View {
    @Bindable var model: ChatModel
    @AppStorage("themeID") private var themeID = Theme.default.id
    @AppStorage("outputFontSize") private var outputFontSize = 13.0
    @AppStorage("outputFontName") private var outputFontName = ""
    @AppStorage("chat.timestamps") private var showTimestamps = false
    @AppStorage("chat.timestampSeconds") private var timestampSeconds = false

    var body: some View {
        VStack(spacing: 0) {
            channelTabs
            Divider()
            MudOutputView(
                store: model.renderStore,
                palette: Theme.with(id: themeID).palette,
                // Two points smaller than the main game window (Channels only).
                fontSize: CGFloat(max(8, outputFontSize - 2)),
                fontName: outputFontName,
                showsLiveTail: true
            )
            .id(model.renderToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            model.setTimestamps(show: showTimestamps, seconds: timestampSeconds)
            await model.start()
        }
        .onChange(of: showTimestamps) { model.setTimestamps(show: showTimestamps, seconds: timestampSeconds) }
        .onChange(of: timestampSeconds) {
            model.setTimestamps(show: showTimestamps, seconds: timestampSeconds)
        }
    }

    // MARK: - Channel tabs (clickable, recency-ordered, horizontally scrollable)

    private var channelTabs: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    tab("All", active: model.selectedChannel == nil) { model.setFilter(nil) }
                    ForEach(model.recentChannels, id: \.self) { channel in
                        tab(channel, active: model.selectedChannel == channel) { model.setFilter(channel) }
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
}
