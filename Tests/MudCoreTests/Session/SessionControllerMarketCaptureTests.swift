import Foundation
@testable import MudCore
import Testing

@Suite("SessionController — market capture")
struct SessionControllerMarketCaptureTests {
    private func line(_ id: UInt64, _ text: String) -> Line {
        Line(id: LineID(id), text: text)
    }

    @Test("Tagged market list is gagged and published")
    func taggedListCapture() async throws {
        let session = SessionController()
        await session.setMarketCaptureEnabled(true)
        var iterator = session.marketCaptures.makeAsyncIterator()

        let summary1 = await session.appendLineThroughScripts(line(1, "{market}"))
        let summary2 = await session.appendLineThroughScripts(line(
            2,
            "Num    Item Description             Lvl  Type Last Bid"
        ))
        let summary3 = await session.appendLineThroughScripts(line(3, "{marketlist}"))
        let summary4 = await session.appendLineThroughScripts(line(
            4,
            " 63212 the Laurels of the Victor    147  Gold        1,050,000*  10   2d 01:42:11"
        ))
        let summary5 = await session.appendLineThroughScripts(line(5, "{/marketlist}"))
        let summary6 = await session.appendLineThroughScripts(line(6, "{/market}"))

        #expect(
            [summary1, summary2, summary3, summary4, summary5, summary6]
                .allSatisfy { $0.gagged == 1 }
        )
        let capture = try #require(await iterator.next())
        #expect(capture.kind == .list(.standard))
        #expect(
            MarketParser.parseItems(from: capture.lines, variant: .standard).first?.number == 63212
        )
    }

    @Test("Detail capture waits for auction metadata footer")
    func detailCapture() async throws {
        let session = SessionController()
        await session.setMarketCaptureEnabled(true)
        await session.armMarketCapture(for: "lbid 63213")
        var iterator = session.marketCaptures.makeAsyncIterator()

        let lines = [
            "+-----------------------------------------------------------------+",
            "| Name       : the Lemniscate                                     |",
            "+-----------------------------------------------------------------+",
            "| Stat Mods  : Hit roll     : +12      Damage roll  : +48         |",
            "+-----------------------------------------------------------------+",
            "| Resist Mods: Slash        : +21      Bash         : +13         |",
            "+-----------------------------------------------------------------+",
            "| Market Item Number    : 63213                                   |",
            "| Current bid           : 19,500,000 gold (Wing)                  |",
            "+-----------------------------------------------------------------+"
        ]
        for (index, text) in lines.enumerated() {
            let summary = await session.appendLineThroughScripts(line(UInt64(index), text))
            #expect(summary.gagged == 1)
        }

        let capture = try #require(await iterator.next())
        #expect(capture.kind == .detail(itemNumber: 63213))
        let detail = MarketParser.makeDetail(from: capture.lines, itemNumber: 63213)
        #expect(detail.title == "the Lemniscate")
        #expect(capture.lines.map(\.text).contains(
            "| Current bid           : 19,500,000 gold (Wing)                  |"
        ))
    }

    @Test("Queued detail and history captures survive an active tagged list")
    func queuedCapturesAfterTaggedList() async throws {
        let session = SessionController()
        await session.setMarketCaptureEnabled(true)
        var iterator = session.marketCaptures.makeAsyncIterator()

        _ = await session.appendLineThroughScripts(line(1, "{market}"))
        await session.armMarketCapture(for: "lbid 63213 tags")
        await session.armMarketCapture(for: "lbid 63213 history tags")
        _ = await session.appendLineThroughScripts(line(
            2,
            "Num    Item Description             Lvl  Type Last Bid"
        ))
        _ = await session.appendLineThroughScripts(line(
            3,
            " 63213 the Lemniscate             121  Gold       19,500,000  10   2d 01:39:53"
        ))
        _ = await session.appendLineThroughScripts(line(4, "{/market}"))

        let promptAfterList = await session.appendLineThroughScripts(line(5, "[1/1hp 1/1mn 1/1mv]>"))
        #expect(promptAfterList.gagged == 1)

        for (index, text) in detailLines.enumerated() {
            let summary = await session.appendLineThroughScripts(line(UInt64(index + 6), text))
            #expect(summary.gagged == 1)
        }
        let promptAfterDetail = await session.appendLineThroughScripts(line(20, "[1/1hp 1/1mn 1/1mv]>"))
        #expect(promptAfterDetail.gagged == 1)

        for (index, text) in historyLines.enumerated() {
            let summary = await session.appendLineThroughScripts(line(UInt64(index + 21), text))
            #expect(summary.gagged == 1)
        }
        let promptAfterHistory = await session.appendLineThroughScripts(line(30, "[1/1hp 1/1mn 1/1mv]>"))
        #expect(promptAfterHistory.gagged == 1)

        let list = try #require(await iterator.next())
        let detail = try #require(await iterator.next())
        let history = try #require(await iterator.next())
        #expect(list.kind == .list(.standard))
        #expect(detail.kind == .detail(itemNumber: 63213))
        #expect(history.kind == .history(itemNumber: 63213))
    }

    @Test("Plain bid result command is gagged and published")
    func plainBidResultCapture() async throws {
        let session = SessionController()
        await session.setMarketCaptureEnabled(true)
        await session.armMarketCapture(for: "lbid 63213 5,000,000")
        var iterator = session.marketCaptures.makeAsyncIterator()

        let result = await session.appendLineThroughScripts(line(
            1,
            "You bid 5,000,000 gold on auction 63213."
        ))
        let prompt = await session.appendLineThroughScripts(line(2, "[1/1hp 1/1mn 1/1mv]>"))

        #expect(result.gagged == 1)
        #expect(prompt.gagged == 1)
        let capture = try #require(await iterator.next())
        #expect(capture.kind == .bidResult(itemNumber: 63213, proxy: false))
    }

    private var detailLines: [String] {
        [
            "+-----------------------------------------------------------------+",
            "| Name       : the Lemniscate                                     |",
            "+-----------------------------------------------------------------+",
            "| Market Item Number    : 63213                                   |",
            "| Current bid           : 19,500,000 gold (Wing)                  |",
            "+-----------------------------------------------------------------+"
        ]
    }

    private var historyLines: [String] {
        [
            "   [ Aardwolf Marketplace - Bid history for Auction 63213 ]",
            "    This is a gold based auction for the Lemniscate",
            "    Bidder       Amount             Time",
            "    ------------ --------------- ----------------",
            "    Wing              19,500,000  23 Jun 19:44:51 (proxy)"
        ]
    }
}
