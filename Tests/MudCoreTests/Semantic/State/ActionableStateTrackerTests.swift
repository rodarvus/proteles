import Foundation
@testable import MudCore
import Testing

/// The actionable-state frame's feed table (S0b item 1, #84): unseen until a
/// feed arrives, and a change reported only when something changed.
@Suite("ActionableStateTracker — feed status")
struct ActionableStateTrackerTests {
    private func line(_ text: String, at seconds: TimeInterval = 0) -> Line {
        Line(id: LineID(0), timestamp: Date(timeIntervalSince1970: seconds), text: text)
    }

    @Test("every feed is unseen at the start")
    func allUnseen() {
        let tracker = ActionableStateTracker()
        for feed in ActionableState.Feed.allCases {
            #expect(!tracker.state.status(of: feed).isSeen)
        }
    }

    @Test("a completed block marks its feed seen, from the line's time, and counts it")
    func blockSeenAndCounted() {
        var tracker = ActionableStateTracker()
        #expect(tracker.ingest(line("{roomchars}", at: 5)) == .none)
        #expect(tracker.ingest(line("A mob is here.")) == .none)
        #expect(tracker.ingest(line("{/roomchars}", at: 6)).state)
        _ = tracker.ingest(line("{roomchars}"))
        #expect(tracker.ingest(line("{/roomchars}", at: 9)).state)
        let status = tracker.state.status(of: .roomchars)
        #expect(status.since == Date(timeIntervalSince1970: 6))
        #expect(status.blocks == 2)
    }

    @Test("a tag line marks its feed seen once and counts every arrival; a repeat reports nothing")
    func tagLineOnce() {
        var tracker = ActionableStateTracker()
        #expect(tracker.ingest(line("{invmon}1,3955293760,-1,-1", at: 3)).state)
        #expect(tracker.ingest(line("{invmon}2,3955293760,-1,-1", at: 4)) == .none)
        #expect(tracker.state.status(of: .invmon).since == Date(timeIntervalSince1970: 3))
        #expect(tracker.state.status(of: .invmon).arrivals == 2)
        #expect(tracker.state.status(of: .invmon).blocks == 0)
    }

    @Test("pending counts are reported once the refresh interval has passed, and not before")
    func countRefresh() {
        var tracker = ActionableStateTracker()
        let refresh = ActionableStateTracker.countRefresh
        let start = Date(timeIntervalSince1970: 100)
        #expect(tracker.ingest(gmcpPackage: "char.vitals", at: start).state)
        #expect(tracker.ingest(gmcpPackage: "char.vitals", at: start + refresh - 1) == .none)
        #expect(tracker.ingest(gmcpPackage: "char.vitals", at: start + refresh).state)
        #expect(tracker.state.status(of: .charVitals).arrivals == 3)
        // Nothing pending: a plain line long afterwards reports nothing.
        #expect(tracker.ingest(line("{roomchars}", at: 100 + 3 * refresh)) == .none)
    }

    @Test("any reported change carries the counts and restarts the refresh interval")
    func blockCarriesCounts() {
        var tracker = ActionableStateTracker()
        let refresh = ActionableStateTracker.countRefresh
        _ = tracker.ingest(line("{exits}north", at: 0))
        _ = tracker.ingest(line("{exits}south", at: 1))
        _ = tracker.ingest(line("{roomchars}", at: 2))
        #expect(tracker.ingest(line("{/roomchars}", at: 2)).state)
        // The block reported at 2 s, so the next count waits until 2 s + refresh.
        #expect(tracker.ingest(line("{exits}east", at: refresh + 1)) == .none)
        #expect(tracker.ingest(line("{exits}west", at: refresh + 2)).state)
        #expect(tracker.state.status(of: .exits).arrivals == 4)
    }

    @Test("GMCP feeds are seen by package name, case-insensitively; others are ignored")
    func gmcpFeeds() {
        var tracker = ActionableStateTracker()
        #expect(tracker.ingest(gmcpPackage: "Char.Vitals").state)
        #expect(tracker.ingest(gmcpPackage: "char.vitals") == .none)
        #expect(tracker.ingest(gmcpPackage: "comm.channel") == .none)
        #expect(tracker.state.status(of: .charVitals).isSeen)
        #expect(!tracker.state.status(of: .roomInfo).isSeen)
    }

    @Test("a feed-status change names no entity")
    func feedChangeNamesNoEntity() {
        var tracker = ActionableStateTracker()
        _ = tracker.ingest(line("{roomchars}"))
        #expect(tracker.ingest(line("{/roomchars}")).entities.isEmpty)
    }

    @Test("an incomplete block is recorded on its feed")
    func incompleteRecorded() {
        var tracker = ActionableStateTracker()
        _ = tracker.ingest(line("{roomchars}"))
        #expect(tracker.ingest(line("{roomobjs}", at: 2)).state)
        let status = tracker.state.status(of: .roomchars)
        #expect(status.incompleteBlocks == 1)
        #expect(status.lastIncomplete?.reason == .interrupted)
        #expect(status.blocks == 0)
    }

    @Test("plain lines change nothing")
    func plainLines() {
        var tracker = ActionableStateTracker()
        #expect(tracker.ingest(line("You are standing.")) == .none)
        #expect(tracker.ingest(line("{affon}614,1200")) == .none)
    }

    @Test("reset makes every feed unseen and forgets an open block")
    func reset() {
        var tracker = ActionableStateTracker()
        _ = tracker.ingest(line("{exits}[ Exits: north ]"))
        _ = tracker.ingest(line("{roomchars}"))
        tracker.reset()
        #expect(tracker.state == ActionableState())
        #expect(tracker.ingest(line("{/roomchars}")) == .none)
        // The first arrival after a reset reports at once, as a first sighting.
        #expect(tracker.ingest(line("{exits}[ Exits: south ]")).state)
        #expect(tracker.state.status(of: .exits).arrivals == 1)
    }
}
