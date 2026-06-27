import MudCore
import SwiftUI

public struct MarketPanelView: View {
    @Bindable private var model: MarketPanelModel
    @FocusState private var focusedField: MarketFocus?

    public init(model: MarketPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                listingPane
                    .frame(minWidth: 380, idealWidth: 520)
                detailPane
                    .frame(minWidth: 320, idealWidth: 420)
            }
            footer
        }
        .frame(minWidth: 760, minHeight: 420)
        .task {
            if model.items.isEmpty { model.refresh() }
            focusedField = .listing
        }
        .onChange(of: model.selectedItemNumber) { _, _ in
            focusedField = .listing
        }
        .onExitCommand {
            model.cancelBid()
            focusedField = .listing
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.listMode) {
                ForEach(MarketPanelModel.ListMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.listMode) { _, _ in
                model.activeFilter = nil
                model.refresh()
            }

            filterMenu

            Spacer()

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh marketplace")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterMenu: some View {
        Menu {
            Button("No filter") {
                model.activeFilter = nil
                model.refresh()
            }
            Divider()
            ForEach(MarketPanelModel.Filter.allCases) { filter in
                Button(filter.label) {
                    model.activeFilter = filter
                    model.refresh()
                }
            }
        } label: {
            Label(model.activeFilter?.label ?? "Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter marketplace listings")
    }

    private var listingPane: some View {
        VStack(spacing: 0) {
            listingHeader
            Divider()
            if model.items.isEmpty {
                placeholder("tray", "No Listings", model.status)
            } else {
                List(selection: selectedItemBinding) {
                    ForEach(model.items) { item in
                        MarketRow(
                            item: item,
                            selected: item.number == model.selectedItem?.number,
                            mode: model.listMode
                        )
                        .tag(item.number)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }
                .listStyle(.plain)
                .focused($focusedField, equals: .listing)
            }
        }
    }

    private var listingHeader: some View {
        HStack(spacing: 8) {
            Text("Num").frame(width: MarketColumns.number, alignment: .leading)
            Text("Item").frame(maxWidth: .infinity, alignment: .leading)
            Text("Lvl").frame(width: MarketColumns.level, alignment: .trailing)
            Text("Bid").frame(width: MarketColumns.bid, alignment: .trailing)
            Text(model.listMode == .sellers ? "Seller" : "Left")
                .frame(width: MarketColumns.trailing, alignment: .trailing)
        }
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let item = model.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let detail = model.displayDetail {
                            sectionTitle("Details")
                            detailBlock(detail)
                        } else {
                            placeholder("doc.text.magnifyingglass", "Select Details", "Select an item.")
                                .frame(minHeight: 160)
                        }
                        historySection
                    }
                    .padding(14)
                }
                Divider()
                bidBar(item)
            } else {
                placeholder("cart", "Marketplace", "Refresh to load current listings.")
            }
        }
    }

    private func detailBlock(_ detail: MarketDetail) -> some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(Array(detail.displayLines.enumerated()), id: \.offset) { _, line in
                Text(line.attributedText())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Bid History")

            if let history = model.displayHistory {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(historyDisplayLines(history).enumerated()), id: \.offset) { _, line in
                        Text(line.attributedText())
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            } else if model.displayHistory == nil {
                Text("Loading history...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No bid history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func bidBar(_ item: MarketItem) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Amount", text: $model.bidAmount)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .focused($focusedField, equals: .amount)
                    .onSubmit {
                        model.prepareBid()
                        focusedField = .review
                    }
                Toggle("Proxy", isOn: $model.proxyBid)
                    .toggleStyle(.checkbox)
                Spacer()
                Button {
                    model.prepareBid()
                    focusedField = .review
                } label: {
                    Label("Review Bid", systemImage: "hammer")
                }
                .disabled(item.number != model.selectedItem?.number || !model.canPrepareBid)
            }
            if let review = model.bidReview {
                Divider()
                inlineBidReview(review)
                    .focused($focusedField, equals: .review)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let lastUpdated = model.lastUpdated {
                Text(lastUpdated, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35))
    }

    private func inlineBidReview(_ review: MarketPanelModel.BidReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(review.proxy ? "Review Proxy Bid" : "Review Bid")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(review.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 14) {
                reviewValue("Auction", "#\(review.item.number)")
                reviewValue("Amount", format(review.amount))
                reviewValue("Current", format(review.item.lastBid))
                reviewValue("Proxy", review.proxy ? "Yes" : "No")
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel) {
                    model.cancelBid()
                    focusedField = .listing
                }
                Button(review.proxy ? "Place Proxy Bid" : "Place Bid") {
                    model.confirmBid(review)
                    focusedField = .listing
                }
            }
            Text(review.item.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .focusable()
    }

    private func reviewValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    private func historyDisplayLines(_ history: MarketBidHistory) -> [Line] {
        let lines = history.rawLines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if !lines.isEmpty { return lines }
        return [Line(id: LineID(0), text: "No bid history.")]
    }

    private func placeholder(_ icon: String, _ title: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func format(_ amount: Int?) -> String {
        guard let amount else { return "--" }
        return amount.formatted(.number.grouping(.automatic))
    }

    private var selectedItemBinding: Binding<Int?> {
        Binding(
            get: { model.selectedItemNumber },
            set: { number in
                model.chooseItem(number: number)
                focusedField = .listing
            }
        )
    }
}

private enum MarketFocus: Hashable {
    case listing
    case amount
    case review
}

private enum MarketColumns {
    static let number: CGFloat = 56
    static let level: CGFloat = 30
    static let bid: CGFloat = 82
    static let trailing: CGFloat = 74
}

private struct MarketRow: View {
    let item: MarketItem
    let selected: Bool
    let mode: MarketPanelModel.ListMode

    var body: some View {
        HStack(spacing: 8) {
            Text("\(item.number)")
                .frame(width: MarketColumns.number, alignment: .leading)
            itemName
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            Text(item.level.map(String.init) ?? "--")
                .frame(width: MarketColumns.level, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(price)
                .frame(width: MarketColumns.bid, alignment: .trailing)
                .foregroundStyle(item.isHighBidder ? .green : .primary)
            Text(trailing)
                .frame(width: MarketColumns.trailing, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .help(item.name)
    }

    private var price: String {
        (item.buyout ?? item.lastBid)?.formatted(.number.grouping(.automatic)) ?? "--"
    }

    private var tint: Color {
        switch item.type.lowercased() {
        case "gold", "g":
            .yellow
        case "quest", "qp":
            .cyan
        case "tp":
            .purple
        default:
            .primary
        }
    }

    @ViewBuilder
    private var itemName: some View {
        if let nameLine = item.nameLine, !nameLine.runs.isEmpty {
            Text(nameLine.attributedText())
        } else {
            Text(item.name)
                .foregroundStyle(tint)
        }
    }

    private var trailing: String {
        switch mode {
        case .sellers:
            item.seller ?? "--"
        case .buyouts:
            item.lastBidder ?? "--"
        case .all:
            item.timeLeft ?? "--"
        }
    }
}
