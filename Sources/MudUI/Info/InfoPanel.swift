import MudCore
import SwiftUI

/// The **Character** miniwindow: a compact, single-column stat block over GMCP
/// state — modelled on the Aardwolf `aard_statmon` plugin (stats / hitroll-damroll,
/// resources, level/TNL/align, vitals, and the current foe). Monospaced with
/// bracketed, right-aligned values; hugs its content so it resizes neatly. Group
/// members live in their own window now (GH #38), not here.
public struct InfoPanel: View {
    private let state: GMCPState
    @AppStorage("themeID") private var themeID = Theme.default.id

    public init(state: GMCPState) {
        self.state = state
    }

    private var palette: ColorPalette {
        Theme.with(id: themeID).palette
    }

    private var goldColor: Color {
        Color(rgb: 0xE6C200)
    }

    private var hasData: Bool {
        state.stats != nil || state.status != nil || state.vitals != nil || state.worth != nil
    }

    public var body: some View {
        Group {
            if hasData {
                VStack(alignment: .leading, spacing: 2) {
                    statsGroup
                    gap
                    resourcesGroup
                    gap
                    progressGroup
                    gap
                    vitalsGroup
                }
            } else {
                Text("Connect and log in to see character stats.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color(palette.defaultBackground))
    }

    private var gap: some View {
        Color.clear.frame(height: 8)
    }

    // MARK: - Groups

    @ViewBuilder private var statsGroup: some View {
        let stats = state.stats
        let max = state.maxStats
        line("Str", pair(stats?.str, max.flatMap(\.maxstr)))
        line("Int", pair(stats?.int, max.flatMap(\.maxint)))
        line("Wis", pair(stats?.wis, max.flatMap(\.maxwis)))
        line("Dex", pair(stats?.dex, max.flatMap(\.maxdex)))
        line("Con", pair(stats?.con, max.flatMap(\.maxcon)))
        line("Luk", pair(stats?.luck, max.flatMap(\.maxluck)))
        line("HR", num(stats?.hr))
        line("DR", num(stats?.dr))
    }

    @ViewBuilder private var resourcesGroup: some View {
        let worth = state.worth
        line("Train", num(worth.flatMap(\.trains)))
        line("Prac", num(worth.flatMap(\.pracs)))
        line("Gold", num(worth.flatMap(\.gold)), color: goldColor)
        line("TP", num(worth.flatMap(\.tp)))
        line("QP", num(worth.flatMap(\.qp)))
    }

    @ViewBuilder private var progressGroup: some View {
        let status = state.status
        line("Lvl", num(status.map(\.level)))
        line("TNL", num(status.flatMap(\.tnl)))
        line("Align", num(status.flatMap(\.align)))
    }

    @ViewBuilder private var vitalsGroup: some View {
        let vitals = state.vitals
        let max = state.maxStats
        line("Hp", pair(vitals?.hp, max.map(\.maxhp)))
        line("Mn", pair(vitals?.mana, max.map(\.maxmana)))
        line("Mvs", pair(vitals?.moves, max.map(\.maxmoves)))
        foeLine(state.status?.enemy)
    }

    // MARK: - Rows

    /// A `Label : [    value ]` row — label dimmed, value right-aligned + tinted.
    private func line(_ label: String, _ value: String, color: Color = .primary) -> some View {
        (Text("\(pad(label)) : [ ").foregroundStyle(.secondary)
            + Text(rightAlign(value)).foregroundStyle(color)
            + Text(" ]").foregroundStyle(.secondary))
            .font(.system(.callout, design: .monospaced))
    }

    /// The foe row: the target name (left-aligned, since it's not a number),
    /// shown red while a foe is engaged and dimmed/empty otherwise.
    private func foeLine(_ enemy: String?) -> some View {
        let active = !(enemy ?? "").isEmpty
        return (Text("\(pad("Foe")) : [ ").foregroundStyle(.secondary)
            + Text(active ? enemy! : "").foregroundStyle(active ? Color.red : Color.secondary)
            + Text(" ]").foregroundStyle(.secondary))
            .font(.system(.callout, design: .monospaced))
    }

    // MARK: - Formatting

    /// Left-pad the label to a fixed width so the colons line up.
    private func pad(_ label: String) -> String {
        label.padding(toLength: 5, withPad: " ", startingAt: 0)
    }

    /// Right-align a value within a fixed column so the `]` line up.
    private func rightAlign(_ value: String, width: Int = 9) -> String {
        String(repeating: " ", count: Swift.max(0, width - value.count)) + value
    }

    private func num(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    private func pair(_ current: Int?, _ maximum: Int?) -> String {
        guard let current else { return "-" }
        return maximum.map { "\(current)/\($0)" } ?? "\(current)"
    }
}
