import MudCore
import SwiftUI

/// The chat-capture window: a channel filter over a scrolling, styled log
/// of `comm.channel` lines (PLAN.md §8.5).
public struct ChatView: View {
    @Bindable private var model: ChatModel

    public init(model: ChatModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            channelFilter
            Divider()
            content
        }
        .task { await model.start() }
    }

    private var channelFilter: some View {
        HStack {
            Picker("Channel", selection: $model.selectedChannel) {
                Text("All channels").tag(String?.none)
                ForEach(model.channels, id: \.self) { channel in
                    Text(channel).tag(String?.some(channel))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if model.filteredLines.isEmpty {
            ContentUnavailableView(
                "No Chat Yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Channel and tell messages appear here once you're connected.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            chatList
        }
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.filteredLines) { chatLine in
                        Text(chatLine.line.attributedText())
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(chatLine.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: model.filteredLines.count) {
                guard let last = model.filteredLines.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
