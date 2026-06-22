import MudCore
import SwiftUI

/// The **Character** miniwindow: a compact, single-column stat block over GMCP
/// state — modelled on the Aardwolf `aard_statmon` plugin (stats / hitroll-damroll,
/// resources, level/TNL/align, vitals, and the current foe). Monospaced with
/// bracketed, right-aligned values; hugs its content so it resizes neatly. Group
/// members live in their own window now (GH #38), not here.
public struct InfoPanel: View {
    private let model: GMCPStateModel
    /// Reads route through the model so per-GMCP updates re-render only this
    /// panel, never the root that passed the reference (#61).
    private var state: GMCPState {
        model.state
    }

    @AppStorage("themeID") private var themeID = Theme.default.id
    @AppStorage("themeRevision") private var themeRevision = 0
    /// 1 except in a translucent floating miniwindow (see FloatingMiniWindow).
    @Environment(\.panelBackgroundOpacity) private var panelBackgroundOpacity

    /// Inside a translucent miniwindow the chrome's material is the one
    /// backdrop — painting our theme fill on top of it COMPOUNDS opacity
    /// (0.7 × 0.7 ≈ 0.91, so the panel barely faded — live report,
    /// 2026-06-10). Drop the fill entirely there; keep it when docked.
    private var fillOpacity: Double {
        panelBackgroundOpacity < 1 ? 0 : 1
    }

    public init(state: GMCPStateModel) {
        model = state
    }

    private var palette: ColorPalette {
        _ = themeRevision
        return Theme.with(id: themeID).palette
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
        .background(Color(palette.defaultBackground).opacity(fillOpacity))
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
            .font(.system(.footnote, design: .monospaced))
    }

    /// The foe row: no brackets, and the name is **truncated** (…) rather than
    /// allowed to widen the (content-hugging) window when a long-named foe is
    /// engaged. Red while engaged, empty otherwise.
    private func foeLine(_ enemy: String?) -> some View {
        let name = enemy ?? ""
        let active = !name.isEmpty
        let shown = name.count > 13 ? name.prefix(12) + "…" : name[...]
        return (Text("\(pad("Foe")) : ").foregroundStyle(.secondary)
            + Text(String(shown)).foregroundStyle(active ? Color.red : Color.secondary))
            .font(.system(.footnote, design: .monospaced))
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
