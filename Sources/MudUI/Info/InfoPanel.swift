import MudCore
import SwiftUI

/// Right-hand info sidebar for the main window: current room and character
/// worth, driven by GMCP state (PLAN.md §8.5). Sections appear as their
/// data arrives.
public struct InfoPanel: View {
    private let state: GMCPState

    public init(state: GMCPState) {
        self.state = state
    }

    /// Canonical exit ordering; anything unknown sorts after, alphabetically.
    private static let exitOrder = ["n", "e", "s", "w", "u", "d", "ne", "nw", "se", "sw"]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let room = state.room {
                    roomSection(room)
                }
                if let group = state.group, group.isGrouped {
                    groupSection(group)
                }
                if let worth = state.worth {
                    worthSection(worth)
                }
                if state.room == nil, state.worth == nil, state.group == nil {
                    Text("Connect and log in to see room and character info.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
    }

    private func roomSection(_ room: RoomInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Room")
            Text(AardwolfColor.styledLine(from: room.name).attributedText())
                .font(.headline)
            if let zone = room.zone, !zone.isEmpty {
                row("Area", zone)
            }
            if let terrain = room.terrain, !terrain.isEmpty {
                row("Terrain", terrain)
            }
            if let exits = room.exits, !exits.isEmpty {
                row("Exits", orderedExits(exits))
            }
            row("Vnum", String(room.num))
        }
    }

    private func worthSection(_ worth: CharWorth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Worth")
            if let gold = worth.gold { row("Gold", gold.formatted()) }
            if let qp = worth.qp { row("Quest pts", qp.formatted()) }
            if let tp = worth.tp { row("Trivia pts", tp.formatted()) }
            if let trains = worth.trains { row("Trains", trains.formatted()) }
            if let pracs = worth.pracs { row("Pracs", pracs.formatted()) }
        }
    }

    private func groupSection(_ group: GroupInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(group.groupname?.isEmpty == false ? "Group · \(group.groupname!)" : "Group")
            ForEach(group.members ?? []) { member in
                memberRow(member)
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: GroupInfo.Member) -> some View {
        let info = member.info
        let hpFraction: Double = {
            guard let cur = info?.hpCurrent, let max = info?.hpMax, max > 0 else { return 0 }
            return Swift.max(0, Swift.min(1, Double(cur) / Double(max)))
        }()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(member.name)
                    .font(.callout)
                    .foregroundStyle(info?.isHere == false ? .secondary : .primary)
                if let level = info?.level {
                    Text("L\(level)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Capsule()
                .fill(.quaternary)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(.red)
                            .frame(width: geo.size.width * hpFraction)
                    }
                }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func orderedExits(_ exits: [String: Int]) -> String {
        exits.keys.sorted { lhs, rhs in
            let li = Self.exitOrder.firstIndex(of: lhs) ?? Int.max
            let ri = Self.exitOrder.firstIndex(of: rhs) ?? Int.max
            return li == ri ? lhs < rhs : li < ri
        }.joined(separator: ", ")
    }
}
