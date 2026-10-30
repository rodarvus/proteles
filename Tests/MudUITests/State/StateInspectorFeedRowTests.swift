import Foundation
@testable import MudCore
import MudUI
import Testing

/// The State inspector's feed rows (S0b item 1, #84).
@Suite("StateInspectorFeedRow")
struct StateInspectorFeedRowTests {
    private let utc = TimeZone(identifier: "UTC") ?? .current

    private func line(_ text: String, at seconds: TimeInterval) -> Line {
        Line(id: LineID(0), timestamp: Date(timeIntervalSince1970: seconds), text: text)
    }

    @Test("every feed is listed, unseen ones as not seen")
    func unseen() {
        let rows = StateInspectorFeedRow.rows(for: ActionableState(), timeZone: utc)
        #expect(rows.map(\.feed) == ActionableState.Feed.allCases)
        #expect(rows
            .allSatisfy { !$0.isSeen && $0.status == "Not seen this connection" && $0.warning == nil })
        #expect(rows.first?.name == "{roomchars}")
        #expect(rows.last?.name == "char.status")
    }

    @Test("a seen feed shows its time and its blocks, lines or packets")
    func seen() throws {
        var tracker = ActionableStateTracker()
        _ = tracker.ingest(line("{roomchars}", at: 0))
        _ = tracker.ingest(line("{/roomchars}", at: 3600))
        _ = tracker.ingest(line("{exits}north", at: 3600))
        _ = tracker.ingest(line("{exits}south", at: 3601))
        _ = tracker.ingest(gmcpPackage: "room.info", at: Date(timeIntervalSince1970: 7200))
        let rows = StateInspectorFeedRow.rows(for: tracker.state, timeZone: utc)
        let roomchars = try #require(rows.first { $0.feed == .roomchars })
        #expect(roomchars.isSeen)
        #expect(roomchars.status == "Since \(time(3600)) · 1 block")
        #expect(roomchars.kind == "Tag block")
        let exits = try #require(rows.first { $0.feed == .exits })
        #expect(exits.status == "Since \(time(3600)) · 2 lines")
        #expect(exits.kind == "Tag line")
        let room = try #require(rows.first { $0.feed == .roomInfo })
        #expect(room.status == "Since \(time(7200)) · 1 packet")
        #expect(room.kind == "GMCP")
    }

    /// The row's own time format, in UTC.
    private func time(_ seconds: TimeInterval) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .standard)
        style.timeZone = utc
        return Date(timeIntervalSince1970: seconds).formatted(style)
    }

    @Test("an incomplete block shows a warning")
    func warning() throws {
        var tracker = ActionableStateTracker()
        _ = tracker.ingest(line("{roomchars}", at: 0))
        _ = tracker.ingest(line("A mob.", at: 0))
        _ = tracker.ingest(line("{roomobjs}", at: 0))
        let row = try #require(StateInspectorFeedRow.rows(for: tracker.state, timeZone: utc).first)
        #expect(row.warning?.hasPrefix("1 incomplete; last interrupted after 1 lines") == true)
    }
}
