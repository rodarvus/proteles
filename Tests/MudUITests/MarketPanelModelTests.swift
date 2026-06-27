import MudCore
@testable import MudUI
import Testing

@MainActor
@Suite("MarketPanelModel")
struct MarketPanelModelTests {
    @Test("List load selects first item, then requests history after details arrive")
    func listLoadRequestsSelectedItemPayloads() {
        let model = MarketPanelModel()
        var commands: [String] = []
        model.onCommand = { commands.append($0) }

        model.apply(.init(kind: .list(.standard), lines: [
            line(" 63213 the Lemniscate             121  Gold       19,500,000  10   2d 01:39:53")
        ]))

        #expect(model.selectedItemNumber == 63213)
        #expect(commands == ["lbid 63213"])

        model.apply(.init(kind: .detail(itemNumber: 63213), lines: [
            line("| Name       : the Lemniscate                                     |"),
            line("| Market Item Number    : 63213                                   |")
        ]))

        #expect(commands == [
            "lbid 63213",
            "lbid 63213 history tags"
        ])
    }

    @Test("Three-space history rows are displayed")
    func threeSpaceHistoryRowsDisplay() {
        let model = MarketPanelModel()
        model.apply(.init(kind: .list(.standard), lines: [
            line(" 63310 Cartman Fantasy Series Collector's Card 201  Gold 5,303,030  4 18:43:24")
        ]))

        model.apply(.init(kind: .history(itemNumber: 63310), lines: [
            line("   [ Aardwolf Marketplace - Bid history for Auction 63310 ]"),
            line("   This is a gold based auction for Cartman Fantasy Series Collector's Card"),
            line("   Bidder       Amount             Time"),
            line("   ------------ --------------- ----------------"),
            line("   ChuJun             5,303,030  24 Jun 23:35:07 (proxy)")
        ]))

        #expect(model.displayHistory?.rows.count == 1)
        #expect(model.displayHistory?.rows.first?.bidder == "ChuJun")
        #expect(model.displayHistory?.rows.first?.amount == 5_303_030)
        #expect(model.displayHistory?.rows.first?.isProxy == true)
    }

    @Test("Changing item clears pending bid state")
    func changingItemClearsPendingBidState() {
        let model = MarketPanelModel()
        model.apply(.init(kind: .list(.standard), lines: [
            line(" 63213 the Lemniscate             121  Gold       19,500,000  10   2d 01:39:53"),
            line(" 63214 a bright test wand          10  Gold              501   1      00:39:53")
        ]))
        model.bidAmount = "5000000"
        model.proxyBid = true
        model.prepareBid()

        model.chooseItem(number: 63214)

        #expect(model.bidAmount.isEmpty)
        #expect(model.proxyBid == false)
        #expect(model.bidReview == nil)
    }

    @Test("Stale details do not request history for an old selection")
    func staleDetailsDoNotRequestHistory() {
        let model = MarketPanelModel()
        var commands: [String] = []
        model.onCommand = { commands.append($0) }

        model.apply(.init(kind: .list(.standard), lines: [
            line(" 63213 the Lemniscate             121  Gold       19,500,000  10   2d 01:39:53"),
            line(" 63214 a bright test wand          10  Gold              501   1      00:39:53")
        ]))
        model.chooseItem(number: 63214)

        #expect(commands == ["lbid 63213", "lbid 63214"])

        model.apply(.init(kind: .detail(itemNumber: 63213), lines: [
            line("| Name       : the Lemniscate                                     |"),
            line("| Market Item Number    : 63213                                   |")
        ]))

        #expect(commands == ["lbid 63213", "lbid 63214"])

        model.apply(.init(kind: .detail(itemNumber: 63214), lines: [
            line("| Name       : a bright test wand                                 |"),
            line("| Market Item Number    : 63214                                   |")
        ]))

        #expect(commands == ["lbid 63213", "lbid 63214", "lbid 63214 history tags"])
    }

    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }
}
