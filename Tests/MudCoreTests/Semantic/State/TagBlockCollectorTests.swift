import Foundation
@testable import MudCore
import Testing

/// The tag-block collector (S0b item 1, #84): blocks as recorded, and the
/// edge rules the corpus has never needed (`docs/plans/S0B_ITEM1_PROPOSAL.md`).
@Suite("TagBlockCollector — Aardwolf tag blocks")
struct TagBlockCollectorTests {
    private func line(_ text: String, at seconds: TimeInterval = 0) -> Line {
        Line(id: LineID(0), timestamp: Date(timeIntervalSince1970: seconds), text: text)
    }

    private func feed(
        _ texts: [String],
        into collector: inout TagBlockCollector
    ) -> [TagBlockCollector.Outcome] {
        texts.map { collector.ingest(line($0)) }
    }

    @Test("a recorded {roomchars} block completes with its lines")
    func roomcharsBlock() {
        var collector = TagBlockCollector()
        let outcomes = feed([
            "{roomchars}",
            "(R) The seething crossbill flies through the sky, making mischief with every flap.",
            "(F)(G) The starflier gracefully weaves through the celestial currents.",
            "{/roomchars}"
        ], into: &collector)
        #expect(outcomes[0].opened == .roomchars)
        #expect(outcomes[1] == .none && outcomes[2] == .none)
        let block = outcomes[3].completed
        #expect(block?.feed == .roomchars)
        #expect(block?.arguments.isEmpty == true)
        #expect(block?.lines.map(\.text) == [
            "(R) The seething crossbill flies through the sky, making mischief with every flap.",
            "(F)(G) The starflier gracefully weaves through the celestial currents."
        ])
        #expect(!collector.isCollecting)
    }

    @Test("an opening marker's arguments are kept", arguments: [
        ("{spellheaders hsp}", "{/spellheaders}", "hsp"),
        ("{invdata 3629436877}", "{/invdata}", "3629436877"),
        ("{eqdata}", "{/eqdata}", "")
    ])
    func arguments(open: String, close: String, expected: String) {
        var collector = TagBlockCollector()
        let outcomes = feed([open, "3,acid blast,1,0,0,-1,1", close], into: &collector)
        #expect(outcomes[2].completed?.arguments == expected)
        #expect(outcomes[2].completed?.lines.count == 1)
    }

    @Test("an empty block completes with no lines — seen and empty, not absent")
    func emptyBlock() {
        var collector = TagBlockCollector()
        let outcomes = feed(["{roomobjs}", "{/roomobjs}"], into: &collector)
        #expect(outcomes[1].completed == TagBlockCollector.Block(feed: .roomobjs, arguments: "", lines: []))
    }

    @Test("lines outside any block, and tags of other families, are not collected")
    func outsideLines() {
        var collector = TagBlockCollector()
        let outcomes = feed(
            ["You are standing.", "{exits}[ Exits: north ]", "{affon}614,1200"],
            into: &collector
        )
        #expect(outcomes.allSatisfy { $0 == .none })
        #expect(!collector.isCollecting)
    }

    @Test("another family's tag inside a block stays a line of the block")
    func otherTagInsideBlock() {
        var collector = TagBlockCollector()
        let outcomes = feed(["{roomchars}", "{exits}[ Exits: north ]", "{/roomchars}"], into: &collector)
        #expect(outcomes[2].completed?.lines.map(\.text) == ["{exits}[ Exits: north ]"])
    }

    @Test("a new opening interrupts the open block, which is reported, and starts its own")
    func interruptedByOpening() {
        var collector = TagBlockCollector()
        let outcomes = [
            collector.ingest(line("{roomchars}")),
            collector.ingest(line("A mob is here.")),
            collector.ingest(line("{roomobjs}", at: 7))
        ]
        #expect(outcomes[2].dropped == TagBlockCollector.Drop(
            feed: .roomchars, reason: .interrupted, at: Date(timeIntervalSince1970: 7), lineCount: 1
        ))
        #expect(outcomes[2].opened == .roomobjs)
        #expect(collector.ingest(line("{/roomobjs}")).completed?.feed == .roomobjs)
    }

    @Test("a mismatched closing marker drops the open block")
    func interruptedByClosing() {
        var collector = TagBlockCollector()
        let outcomes = feed(["{invdata}", "1,IM,a thing,1,1,1,-1,-1", "{/eqdata}"], into: &collector)
        #expect(outcomes[2].dropped?.reason == .interrupted)
        #expect(outcomes[2].completed == nil && outcomes[2].opened == nil)
        #expect(!collector.isCollecting)
    }

    @Test("a stray closing marker with nothing open is ignored")
    func strayClosing() {
        var collector = TagBlockCollector()
        #expect(collector.ingest(line("{/roomchars}")) == .none)
    }

    @Test("a block reaching the cap is dropped as overflow; its late closing is ignored")
    func overflow() {
        var collector = TagBlockCollector()
        _ = collector.ingest(line("{spellheaders}"))
        var last = TagBlockCollector.Outcome.none
        for index in 0..<TagBlockCollector.lineCap {
            last = collector.ingest(line("\(index),spell,1,0,0,-1,1"))
        }
        #expect(last.dropped?.reason == .overflow)
        #expect(last.dropped?.lineCount == TagBlockCollector.lineCap)
        #expect(!collector.isCollecting)
        #expect(collector.ingest(line("{/spellheaders}")) == .none)
    }

    @Test("reset forgets an open block")
    func reset() {
        var collector = TagBlockCollector()
        _ = collector.ingest(line("{roomchars}"))
        collector.reset()
        #expect(!collector.isCollecting)
        #expect(collector.ingest(line("{/roomchars}")) == .none)
    }
}
