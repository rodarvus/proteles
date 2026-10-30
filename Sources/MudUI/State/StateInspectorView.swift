import Foundation
import MudCore
import SwiftUI

/// The State inspector (S0b item 1, #84): a read-only view of the live
/// actionable-state model, so the player can verify each S0b entity in play.
/// A debugging surface, not a lens; it enables no feed (#87 owns that).
/// Item 1 shows the feed table; each later item adds its entity's section
/// (`docs/plans/S0B_ITEM1_PROPOSAL.md` §3.4).
public struct StateInspectorView: View {
    private let model: ActionableStateModel

    public init(model: ActionableStateModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                ForEach(StateInspectorFeedRow.rows(for: model.state), id: \.feed) { row in
                    LabeledContent {
                        VStack(alignment: .trailing) {
                            Text(row.status)
                                .foregroundStyle(row.isSeen ? .primary : .secondary)
                            if let warning = row.warning {
                                Text(warning).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    } label: {
                        Text(row.name).font(.body.monospaced())
                        Text(row.kind)
                    }
                }
            } header: {
                Text("Feeds")
            } footer: {
                Text("What the game has sent this connection. A feed that is not seen leaves "
                    + "its entities unknown, never empty. Proteles doesn't switch feeds on here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One feed as the inspector lists it. Pure, so it is tested without a view.
public struct StateInspectorFeedRow: Sendable, Equatable {
    public let feed: ActionableState.Feed
    /// `{roomchars}`, `room.info`.
    public let name: String
    /// "Tag block", "Tag line", "GMCP".
    public let kind: String
    /// "Not seen this connection", or "Since 18:49:36" plus the block count
    /// (tag blocks) or the lines or packets received (tag lines, GMCP).
    public let status: String
    public let isSeen: Bool
    /// The most recent incomplete block, when there is one.
    public let warning: String?

    /// The rows for every feed, in the model's order.
    public static func rows(for state: ActionableState, timeZone: TimeZone = .current) -> [Self] {
        ActionableState.Feed.allCases.map { feed in
            let status = state.status(of: feed)
            return Self(
                feed: feed,
                name: feed.kind == .gmcp ? feed.rawValue : "{\(feed.rawValue)}",
                kind: kindText(feed.kind),
                status: statusText(status, kind: feed.kind, timeZone: timeZone),
                isSeen: status.isSeen,
                warning: status.lastIncomplete.map { drop in
                    "\(status.incompleteBlocks) incomplete; last \(drop.reason.rawValue) "
                        + "after \(drop.lineCount) lines at \(time(drop.at, timeZone: timeZone))"
                }
            )
        }
    }

    private static func kindText(_ kind: ActionableState.Feed.Kind) -> String {
        switch kind {
        case .tagBlock: "Tag block"
        case .tagLine: "Tag line"
        case .gmcp: "GMCP"
        }
    }

    private static func statusText(
        _ status: ActionableState.FeedStatus,
        kind: ActionableState.Feed.Kind,
        timeZone: TimeZone
    ) -> String {
        guard let since = status.since else { return "Not seen this connection" }
        let seen = "Since \(time(since, timeZone: timeZone))"
        switch kind {
        case .tagBlock: return "\(seen) · \(count(status.blocks, "block"))"
        case .tagLine: return "\(seen) · \(count(status.arrivals, "line"))"
        case .gmcp: return "\(seen) · \(count(status.arrivals, "packet"))"
        }
    }

    /// "1 block", "1,234 lines".
    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(value == 1 ? noun : noun + "s")"
    }

    private static func time(_ date: Date, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .standard)
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
