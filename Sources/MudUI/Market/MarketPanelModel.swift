import Foundation
import MudCore
import Observation

@MainActor
@Observable
public final class MarketPanelModel {
    public enum ListMode: String, CaseIterable, Identifiable, Sendable {
        case all
        case sellers
        case buyouts

        public var id: String {
            rawValue
        }

        public var label: String {
            switch self {
            case .all: "All"
            case .sellers: "Sellers"
            case .buyouts: "Buyouts"
            }
        }
    }

    public enum Filter: String, CaseIterable, Identifiable, Sendable {
        case mine
        case outbid
        case qp
        case tp
        case closing
        case showcase

        public var id: String {
            rawValue
        }

        public var label: String {
            switch self {
            case .mine: "Mine"
            case .outbid: "Outbid"
            case .qp: "QP"
            case .tp: "TP"
            case .closing: "Closing"
            case .showcase: "Showcase"
            }
        }
    }

    public struct BidReview: Identifiable, Equatable {
        public var id = UUID()
        public var item: MarketItem
        public var amount: Int
        public var proxy: Bool

        public var command: String {
            proxy
                ? "lbid \(item.number) \(amount) proxy confirm"
                : "lbid \(item.number) \(amount)"
        }
    }

    public private(set) var items: [MarketItem] = []
    public private(set) var detailsByItemNumber: [Int: MarketDetail] = [:]
    public private(set) var historiesByItemNumber: [Int: MarketBidHistory] = [:]
    private var requestedDetailNumbers: Set<Int> = []
    private var requestedHistoryNumbers: Set<Int> = []
    public private(set) var status = "Ready"
    public private(set) var lastUpdated: Date?
    public var selectedItemNumber: Int?
    public var listMode: ListMode = .all
    public var activeFilter: Filter?
    public var bidAmount = ""
    public var proxyBid = false
    public var bidReview: BidReview?

    public var onCommand: ((String) -> Void)?

    public init() {}

    public var selectedItem: MarketItem? {
        guard let selectedItemNumber else { return items.first }
        return items.first { $0.number == selectedItemNumber }
    }

    public var displayDetail: MarketDetail? {
        guard let number = selectedItem?.number else { return nil }
        return detailsByItemNumber[number]
    }

    public var displayHistory: MarketBidHistory? {
        guard let number = selectedItem?.number else { return nil }
        return historiesByItemNumber[number]
    }

    public func refresh() {
        cancelBid()
        detailsByItemNumber = [:]
        historiesByItemNumber = [:]
        requestedDetailNumbers = []
        requestedHistoryNumbers = []
        status = "Refreshing..."
        onCommand?(refreshCommand())
    }

    public func showDetails(for item: MarketItem) {
        select(item)
        loadSelectedItemPayloads()
    }

    public func showHistory(for item: MarketItem) {
        select(item)
        loadSelectedItemPayloads(forceHistory: true)
    }

    public func chooseItem(number: Int?) {
        guard let number,
              let item = items.first(where: { $0.number == number })
        else {
            selectedItemNumber = nil
            return
        }
        select(item)
        loadSelectedItemPayloads()
    }

    public func prepareBid() {
        guard let item = selectedItem,
              let amount = MarketParser.parseAmount(bidAmount),
              amount > 0
        else {
            status = "Enter a bid amount."
            return
        }
        bidReview = BidReview(item: item, amount: amount, proxy: proxyBid)
    }

    public func confirmBid(_ review: BidReview) {
        status = review.proxy ? "Sending proxy bid..." : "Sending bid..."
        onCommand?(review.command)
        bidReview = nil
        bidAmount = ""
        proxyBid = false
    }

    public func cancelBid() {
        bidReview = nil
    }

    /// Remove listings, pending requests/bids, and command routing when the
    /// Marketplace module is disabled.
    public func reset() {
        items = []
        detailsByItemNumber = [:]
        historiesByItemNumber = [:]
        requestedDetailNumbers = []
        requestedHistoryNumbers = []
        status = "Ready"
        lastUpdated = nil
        selectedItemNumber = nil
        listMode = .all
        activeFilter = nil
        bidAmount = ""
        proxyBid = false
        bidReview = nil
        onCommand = nil
    }

    public func apply(_ capture: MarketCapture) {
        switch capture.kind {
        case .list(let variant):
            let parsed = MarketParser.parseItems(from: capture.lines, variant: variant)
            items = parsed
            if selectedItemNumber == nil || !parsed.contains(where: { $0.number == selectedItemNumber }) {
                selectedItemNumber = parsed.first?.number
            }
            lastUpdated = Date()
            status = parsed.isEmpty ? "No matching listings." : "\(parsed.count) listing(s)."
            loadSelectedItemPayloads()
        case .detail(let itemNumber):
            var detail = MarketParser.makeDetail(from: capture.lines, itemNumber: itemNumber)
            let resolvedItem = detail.itemNumber ?? itemNumber ?? selectedItemNumber
            detail.itemNumber = resolvedItem
            if let resolvedItem {
                detailsByItemNumber[resolvedItem] = detail
                requestedDetailNumbers.remove(resolvedItem)
            }
            updateSelectedItemName(from: detail)
            status = "Details loaded."
            if let resolvedItem, resolvedItem == selectedItemNumber {
                loadHistoryIfNeeded(for: resolvedItem)
            }
        case .history(let itemNumber):
            var history = MarketParser.makeHistory(from: capture.lines, itemNumber: itemNumber)
            let resolvedItem = history.itemNumber ?? itemNumber ?? selectedItemNumber
            history.itemNumber = resolvedItem
            if let resolvedItem {
                historiesByItemNumber[resolvedItem] = history
                requestedHistoryNumbers.remove(resolvedItem)
            }
            status = "History loaded."
        case .bidResult:
            status = capture.lines.map(\.text).joined(separator: " ")
            bidAmount = ""
            proxyBid = false
            refresh()
        }
    }

    public var canPrepareBid: Bool {
        guard let amount = MarketParser.parseAmount(bidAmount) else { return false }
        return amount > 0
    }

    private func select(_ item: MarketItem) {
        if selectedItemNumber != item.number {
            bidAmount = ""
            proxyBid = false
            bidReview = nil
        }
        selectedItemNumber = item.number
    }

    private func loadSelectedItemPayloads(forceHistory: Bool = false) {
        guard let item = selectedItem else { return }
        if detailsByItemNumber[item.number] == nil {
            if !requestedDetailNumbers.contains(item.number) {
                status = "Loading details..."
                requestedDetailNumbers.insert(item.number)
                onCommand?("lbid \(item.number)")
            }
            return
        }
        loadHistoryIfNeeded(for: item.number, force: forceHistory)
    }

    private func loadHistoryIfNeeded(for itemNumber: Int, force: Bool = false) {
        guard !requestedHistoryNumbers.contains(itemNumber) else { return }
        if force || historiesByItemNumber[itemNumber] == nil {
            status = "Loading history..."
            requestedHistoryNumbers.insert(itemNumber)
            onCommand?("lbid \(itemNumber) history tags")
        }
    }

    private func updateSelectedItemName(from detail: MarketDetail?) {
        guard let detail,
              let itemNumber = detail.itemNumber,
              let index = items.firstIndex(where: { $0.number == itemNumber }),
              !detail.title.isEmpty
        else { return }
        items[index].name = detail.title
    }

    private func refreshCommand() -> String {
        if let activeFilter {
            return "lbid -f \(activeFilter.rawValue) tags"
        }
        return switch listMode {
        case .all: "lbid tags"
        case .sellers: "lbid sellers tags"
        case .buyouts: "lbid amounts tags"
        }
    }
}
