import Foundation
@testable import MudCore
import Testing

@Suite("MarketParser")
struct MarketParserTests {
    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    private func styledLine(_ text: String, range: Range<Int>) -> Line {
        Line(
            id: LineID(0),
            text: text,
            runs: [
                StyledRun(
                    utf16Range: range,
                    style: StyleAttributes(foreground: .brightNamed(.yellow))
                )
            ]
        )
    }

    @Test("Tagged market blocks are detected")
    func tags() {
        #expect(MarketParser.isOpenTag("{market}"))
        #expect(MarketParser.isCloseTag("{/market}"))
        #expect(!MarketParser.isOpenTag("{marketlist}"))
    }

    @Test("Standard list rows parse bid/time fields")
    func standardListRow() {
        let row = line(
            " 63212 the Laurels of the Victor    147  Gold        1,050,000*  10   2d 01:42:11"
        )
        let items = MarketParser.parseItems(from: [row], variant: .standard)
        #expect(items.count == 1)
        #expect(items[0].number == 63212)
        #expect(items[0].name == "the Laurels of the Victor")
        #expect(items[0].level == 147)
        #expect(items[0].lastBid == 1_050_000)
        #expect(items[0].bidCount == 10)
        #expect(items[0].timeLeft == "2d 01:42:11")
        #expect(items[0].isHighBidder)
    }

    @Test("List rows preserve styled item-name runs")
    func listRowStyledName() {
        let text = " 63300 (Shiny) . + a bloody tendo 199 G       6,000,000             501 Hotlanta"
        let items = MarketParser.parseItems(from: [
            styledLine(text, range: 7..<33)
        ], variant: .amounts)

        #expect(items.count == 1)
        #expect(items[0].name == "(Shiny) . + a bloody tendo")
        #expect(items[0].nameLine?.text == "(Shiny) . + a bloody tendo")
        #expect(items[0].nameLine?.runs.first?.utf16Range == 0..<26)
    }

    @Test("Amounts list rows parse buyout and last bidder")
    func amountsListRow() {
        let row = line(
            " 63300 (Shiny) . + a bloody tendo 199 G       6,000,000             501 Hotlanta"
        )
        let items = MarketParser.parseItems(from: [row], variant: .amounts)
        #expect(items.count == 1)
        #expect(items[0].number == 63300)
        #expect(items[0].buyout == 6_000_000)
        #expect(items[0].lastBid == 501)
        #expect(items[0].lastBidder == "Hotlanta")
        #expect(items[0].hasBuyout)
    }

    @Test("Seller list rows parse seller and last bidder")
    func sellersListRow() {
        let row = line(" 63213 the Lemniscate             121 G     19,500,000 GentooX      Wing")
        let items = MarketParser.parseItems(from: [row], variant: .sellers)
        #expect(items.count == 1)
        #expect(items[0].number == 63213)
        #expect(items[0].seller == "GentooX")
        #expect(items[0].lastBidder == "Wing")
    }

    @Test("Detail fields parse market item metadata")
    func detailFields() {
        let detail = MarketParser.makeDetail(from: [
            line("| Name       : the Lemniscate                                     |"),
            line("|            : of Market Testing                                  |"),
            line("| Market Item Number    : 63213                                   |"),
            line("| Current bid           : 19,500,000 gold (Wing)                  |")
        ], itemNumber: nil)
        #expect(detail.itemNumber == 63213)
        #expect(detail.title == "the Lemniscate of Market Testing")
        #expect(detail.fields.contains(
            MarketDetailField(label: "Current bid", value: "19,500,000 gold (Wing)")
        ))
    }

    @Test("History rows parse proxy marker")
    func historyRows() {
        let history = MarketParser.makeHistory(from: [
            line("   This is a gold based auction for the Lemniscate"),
            line("   Wing              19,500,000  23 Jun 19:44:51 (proxy)"),
            line("   Dunnaakr          16,000,000  23 Jun 19:44:51")
        ], itemNumber: 63213)
        #expect(history.rows.count == 2)
        #expect(history.rows[0].bidder == "Wing")
        #expect(history.rows[0].amount == 19_500_000)
        #expect(history.rows[0].isProxy)
        #expect(!history.rows[1].isProxy)
    }

    @Test("Market commands classify detail history and proxy confirm")
    func commandKinds() {
        #expect(MarketCommandParser.captureKind(for: "lbid 63213") == .detail(itemNumber: 63213))
        #expect(MarketCommandParser.captureKind(for: "lbid 63213 tags") == .detail(itemNumber: 63213))
        let history = MarketCommandParser.captureKind(for: "market bid 63213 history")
        let taggedHistory = MarketCommandParser.captureKind(for: "market bid 63213 history tags")
        #expect(
            history == .history(itemNumber: 63213)
        )
        #expect(taggedHistory == .history(itemNumber: 63213))
        #expect(MarketCommandParser.captureKind(for: "lbid 63213 5000000 proxy confirm")
            == .bidResult(itemNumber: 63213, proxy: true))
        #expect(MarketCommandParser.captureKind(for: "lbid 63213 5,000,000")
            == .bidResult(itemNumber: 63213, proxy: false))
        #expect(MarketCommandParser.captureKind(for: "lbid tags") == nil)
    }

    @Test("Detail display lines keep item stats but remove frame and auction metadata")
    func detailDisplayLines() {
        let detail = MarketParser.makeDetail(from: [
            line("+-----------------------------------------------------------------+"),
            line("| Name       : the Lemniscate                                     |"),
            line("| Type       : Portal                    Level  :   121           |"),
            line("+-----------------------------------------------------------------+"),
            line("| Market Item Number    : 63213                                   |"),
            line("| Current bid           : 19,500,000 gold (Wing)                  |"),
            line("+-----------------------------------------------------------------+")
        ], itemNumber: nil)

        #expect(detail.displayLines.map(\.text) == [
            "Name       : the Lemniscate",
            "Type       : Portal                    Level  :   121"
        ])
    }
}
