import MudCore
import SwiftUI

/// Full-width graphical vitals bar that spans the bottom of the game output
/// (UI revamp — `docs/UI_REVAMP.md`). HP/MP/MV (and, in combat, the enemy's
/// health) are wide proportional bars sharing the width equally; a small
/// connection dot sits at the leading edge. The old text character summary is
/// dropped here — it lives in the Character panel — so this is purely the
/// at-a-glance graphical readout the user asked for.
public struct GaugeBarView: View {
    private let state: StatusBarView.ConnectionState
    private let gmcp: GMCPState

    public init(state: StatusBarView.ConnectionState, gmcp: GMCPState) {
        self.state = state
        self.gmcp = gmcp
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .help(connectionLabel)

            if let vitals = gmcp.vitals, let max = gmcp.maxStats {
                WideGauge(label: "HP", current: vitals.hp, max: max.maxhp, tint: .red)
                WideGauge(label: "MP", current: vitals.mana, max: max.maxmana, tint: .blue)
                WideGauge(label: "MV", current: vitals.moves, max: max.maxmoves, tint: .green)
                if let target = gmcp.status?.combatTarget {
                    WideGauge(label: target.name, current: target.percent, max: 100, tint: .orange)
                }
            } else {
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .disconnected: .secondary
        case .connecting, .reconnecting: .yellow
        case .connected: .green
        }
    }

    private var connectionLabel: String {
        switch state {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        }
    }
}

/// A wide proportional gauge that fills the available width, with the label and
/// current value laid over the fill.
private struct WideGauge: View {
    let label: String
    let current: Int
    let max: Int
    let tint: Color

    var body: some View {
        let fraction = max > 0 ? Swift.max(0, Swift.min(1, Double(current) / Double(max))) : 0
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: geo.size.width * fraction)
            }
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption2.weight(.bold))
                Spacer(minLength: 4)
                Text("\(current)")
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .padding(.horizontal, 8)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .help("\(label) \(current)/\(max)")
    }
}

#Preview {
    var state = GMCPState()
    state.vitals = CharVitals(hp: 1500, mana: 700, moves: 1100)
    state.maxStats = CharMaxStats(maxhp: 2000, maxmana: 1500, maxmoves: 1400)
    return VStack(spacing: 0) {
        Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
        GaugeBarView(state: .connected, gmcp: state)
    }
    .frame(width: 800, height: 160)
}
