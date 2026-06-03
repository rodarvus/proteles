import MudCore
import SwiftUI

/// Right-hand info sidebar for the main window: current room and character
/// worth, driven by GMCP state (PLAN.md §8.5). Sections appear as their
/// data arrives.
public struct InfoPanel: View {
    private let state: GMCPState

    /// Group-panel view prefs (#17), surfaced via the group header menu.
    @AppStorage("group.roomOnly") private var groupRoomOnly = false
    @AppStorage("group.sort") private var groupSortRaw = GroupMemberSort.standard.rawValue

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
                if let status = state.status {
                    characterSection(status)
                }
                if let status = state.status, let enemy = status.enemy, !enemy.isEmpty {
                    enemySection(name: enemy, percent: status.enemypct)
                }
                if let stats = state.stats {
                    statsSection(stats, max: state.maxStats)
                }
                if let group = state.group, group.isGrouped {
                    groupSection(group)
                }
                if let worth = state.worth {
                    worthSection(worth)
                }
                if isEmpty {
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

    private var isEmpty: Bool {
        state.room == nil && state.worth == nil && state.group == nil
            && state.status == nil && state.stats == nil
    }

    private func characterSection(_ status: CharStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Character")
            row("Level", String(status.level))
            if let tnl = status.tnl {
                row("To next level", tnl.formatted())
            }
            if let align = status.align {
                alignmentSlider(align)
            }
        }
    }

    /// Alignment shown on a −1000…+1000 track with a coloured marker.
    private func alignmentSlider(_ align: Int) -> some View {
        let fraction = Swift.max(0, Swift.min(1, Double(align + 1000) / 2000))
        return VStack(alignment: .leading, spacing: 3) {
            row("Alignment", align.formatted())
            Capsule()
                .fill(.quaternary)
                .frame(height: 6)
                .overlay {
                    GeometryReader { geo in
                        Circle()
                            .fill(alignmentColor(align))
                            .frame(width: 10, height: 10)
                            .position(x: geo.size.width * fraction, y: 3)
                    }
                }
        }
    }

    private func alignmentColor(_ align: Int) -> Color {
        if align >= 350 { return .blue }
        if align <= -350 { return .red }
        return .secondary
    }

    private func enemySection(name: String, percent: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Combat")
            Text(AardwolfColor.styledLine(from: name).attributedText())
                .font(.callout)
            if let percent {
                let fraction = Swift.max(0, Swift.min(1, Double(percent) / 100))
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(.red).frame(width: geo.size.width * fraction)
                        }
                    }
                row("Enemy", "\(percent)%")
            }
        }
    }

    private func statsSection(_ stats: CharStats, max: CharMaxStats?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Stats")
            statRow("Str", stats.str, max?.maxstr)
            statRow("Int", stats.int, max?.maxint)
            statRow("Wis", stats.wis, max?.maxwis)
            statRow("Dex", stats.dex, max?.maxdex)
            statRow("Con", stats.con, max?.maxcon)
            statRow("Luck", stats.luck, max?.maxluck)
            row("Hit roll", stats.hr.formatted())
            row("Dam roll", stats.dr.formatted())
        }
    }

    private func statRow(_ label: String, _ current: Int, _ maximum: Int?) -> some View {
        row(label, maximum.map { "\(current)/\($0)" } ?? current.formatted())
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
        let sort = GroupMemberSort(rawValue: groupSortRaw) ?? .standard
        let members = group.displayMembers(sort: sort, roomOnly: groupRoomOnly)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                header(group.groupname?.isEmpty == false ? "Group · \(group.groupname!)" : "Group")
                Spacer()
                groupMenu
            }
            if members.isEmpty {
                Text(groupRoomOnly ? "No group members in this room." : "No group members.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(members) { member in
                memberRow(member, isLeader: member.name == group.leader)
            }
        }
    }

    /// The group-panel options menu (room filter + sort).
    private var groupMenu: some View {
        Menu {
            Toggle("This room only", isOn: $groupRoomOnly)
            Picker("Sort", selection: $groupSortRaw) {
                ForEach(GroupMemberSort.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func memberRow(_ member: GroupInfo.Member, isLeader: Bool) -> some View {
        let info = member.info
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                alignDot(info?.align)
                Text(member.name)
                    .font(.callout)
                    .foregroundStyle(info?.isHere == false ? .secondary : .primary)
                if isLeader {
                    Image(systemName: "crown.fill").font(.caption2).foregroundStyle(.yellow)
                }
                if let level = info?.level {
                    Text("L\(level)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if let tag = info?.questTag {
                    Text(tag)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(info?.onQuest == true ? .green : .secondary)
                }
                if let current = info?.hpCurrent, let maximum = info?.hpMax {
                    Text("\(current)/\(maximum)").font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            memberBar(Self.fraction(info?.hp, info?.mhp), tint: .red)
            memberBar(Self.fraction(info?.mn, info?.mmn), tint: .blue)
            memberBar(Self.fraction(info?.mv, info?.mmv), tint: .green)
        }
    }

    /// A small alignment dot (good = blue, evil = red, neutral = grey) before
    /// the member's name; absent when the member sends no alignment.
    @ViewBuilder
    private func alignDot(_ alignString: String?) -> some View {
        if let align = alignString.flatMap({ Int($0) }) {
            Circle().fill(alignmentColor(align)).frame(width: 6, height: 6)
        }
    }

    private func memberBar(_ fraction: Double, tint: Color) -> some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(tint).frame(width: geo.size.width * fraction)
                }
            }
    }

    /// Clamp `current/maximum` (both string-valued GMCP fields) to 0…1.
    private static func fraction(_ current: String?, _ maximum: String?) -> Double {
        guard let cur = current.flatMap({ Int($0) }),
              let max = maximum.flatMap({ Int($0) }), max > 0
        else { return 0 }
        return Swift.max(0, Swift.min(1, Double(cur) / Double(max)))
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
