import MudCore
import SwiftUI

/// The **Group** miniwindow (GH #38): a compact, narrow party monitor modelled on
/// Aardwolf's `aard_group_monitor` — per member a header line (level · name ·
/// quest · TNL) over three labelled HP/MN/MV bars with cur/max numbers. Hugs its
/// content so the window stays as narrow as the data needs. Driven by GMCP group
/// state; members can be room-only filtered + sorted via the header menu.
public struct GroupPanel: View {
    private let state: GMCPState
    @AppStorage("group.roomOnly") private var roomOnly = false
    @AppStorage("group.sort") private var sortRaw = GroupMemberSort.standard.rawValue
    /// 1 except in a translucent floating miniwindow, whose chrome material is
    /// the one backdrop — our own material on top would compound opacity
    /// (the Character-panel live report, 2026-06-10).
    @Environment(\.panelBackgroundOpacity) private var panelBackgroundOpacity

    public init(state: GMCPState) {
        self.state = state
    }

    private var sort: GroupMemberSort {
        GroupMemberSort(rawValue: sortRaw) ?? .standard
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let group = state.group, group.isGrouped {
                let members = group.displayMembers(sort: sort, roomOnly: roomOnly)
                if members.isEmpty {
                    placeholder(roomOnly ? "No group members in this room." : "No group members.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(members) { member in
                                memberBlock(member, isLeader: member.name == group.leader)
                            }
                        }
                        .padding(8)
                    }
                }
            } else {
                placeholder("Not in a group.")
            }
        }
        .background(.regularMaterial.opacity(panelBackgroundOpacity < 1 ? 0 : 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            let group = state.group
            VStack(alignment: .leading, spacing: 1) {
                groupTitle(group?.groupname)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let leader = group?.leader, !leader.isEmpty {
                    Text("Leader: \(leader)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            optionsMenu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// "Group: <name>" with the name's Aardwolf `@`-colours parsed + rendered.
    private func groupTitle(_ name: String?) -> Text {
        guard let name, !name.isEmpty else { return Text("Group") }
        return Text("Group: ") + Text(AardwolfColor.styledLine(from: name).attributedText())
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("This room only", isOn: $roomOnly)
            Picker("Sort", selection: $sortRaw) {
                ForEach(GroupMemberSort.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func memberBlock(_ member: GroupInfo.Member, isLeader: Bool) -> some View {
        let info = member.info
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let level = info?.level {
                    Text("L\(level)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                alignDot(info?.align)
                Text(member.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(info?.isHere == false ? .secondary : .primary)
                if isLeader {
                    Image(systemName: "crown.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                }
                Spacer(minLength: 6)
                if let tag = info?.questTag {
                    Text(tag).font(.caption2.monospacedDigit())
                        .foregroundStyle(info?.onQuest == true ? .green : .secondary)
                }
                if let tnl = info?.tnl, let value = Int(tnl) {
                    Text("TNL \(value)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            bar("HP", info?.hp, info?.mhp, tint: .green)
            bar("MN", info?.mn, info?.mmn, tint: .blue)
            bar("MV", info?.mv, info?.mmv, tint: .yellow)
        }
    }

    /// One labelled vitals bar: `HP ▕███▏ cur/max`.
    private func bar(_ label: String, _ current: String?, _ maximum: String?, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .semibold).monospaced())
                .foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
            Capsule().fill(.quaternary).frame(width: 72, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: 72 * Self.fraction(current, maximum), height: 5)
                }
            if let cur = current, let max = maximum {
                Text("\(cur)/\(max)").font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    @ViewBuilder
    private func alignDot(_ alignString: String?) -> some View {
        if let align = alignString.flatMap({ Int($0) }) {
            Circle().fill(alignmentColor(align)).frame(width: 6, height: 6)
        }
    }

    private func alignmentColor(_ align: Int) -> Color {
        if align >= 350 { return .blue }
        if align <= -350 { return .red }
        return .secondary
    }

    private static func fraction(_ current: String?, _ maximum: String?) -> Double {
        guard let cur = current.flatMap({ Int($0) }),
              let max = maximum.flatMap({ Int($0) }), max > 0 else { return 0 }
        return Swift.max(0, Swift.min(1, Double(cur) / Double(max)))
    }
}
