import MudCore
import SwiftUI

/// Status bar along the bottom of the main window: connection state on the
/// left, and — once GMCP data arrives — a character summary and HP/MP/MV
/// gauges on the right (PLAN.md §8.5).
public struct StatusBarView: View {
    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    private let state: ConnectionState
    private let gmcp: GMCPState

    public init(
        state: ConnectionState = .disconnected,
        gmcp: GMCPState = GMCPState()
    ) {
        self.state = state
        self.gmcp = gmcp
    }

    public var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(.callout))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let summary = characterSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let lastTick = gmcp.lastTick {
                tickReadout(lastTick)
            }

            if let vitals = gmcp.vitals, let max = gmcp.maxStats {
                HStack(spacing: 10) {
                    VitalGauge(label: "HP", current: vitals.hp, max: max.maxhp, tint: .red)
                    VitalGauge(label: "MP", current: vitals.mana, max: max.maxmana, tint: .blue)
                    VitalGauge(label: "MV", current: vitals.moves, max: max.maxmoves, tint: .green)
                }
            }

            // Combat opponent's remaining health — only while fighting
            // (the useful slice of aard_health_bars_gmcp).
            if let target = gmcp.status?.combatTarget {
                VitalGauge(label: target.name, current: target.percent, max: 100, tint: .orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
        }
    }

    /// Live "Next tick: N" countdown. `TimelineView` refreshes it every second
    /// off the witnessed-tick anchor — no manual timer — and each new
    /// `comm.tick` re-anchors it (see ``GMCPState/secondsToNextTick``).
    private func tickReadout(_ lastTick: Date) -> some View {
        TimelineView(.periodic(from: lastTick, by: 1)) { context in
            // Self-hide once ticks stop arriving (TickTimer disabled, or
            // disconnected): an anchor older than a grace window has no live
            // countdown. Re-evaluated each second by the timeline.
            let elapsed = context.date.timeIntervalSince(lastTick)
            if elapsed < GMCPState.tickInterval * 2 {
                Text("Next tick: \(GMCPState.secondsToNextTick(lastTick: lastTick, now: context.date))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .disconnected: .secondary
        case .connecting, .reconnecting: .yellow
        case .connected: .green
        }
    }

    private var label: String {
        switch state {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        }
    }

    /// "Lvl 201 · Mage · align 1000" — whichever pieces have arrived.
    private var characterSummary: String? {
        var parts: [String] = []
        if let level = gmcp.status?.level {
            parts.append("Lvl \(level)")
        }
        if let tnl = gmcp.status?.tnl {
            parts.append("TNL \(tnl)")
        }
        if let className = gmcp.base?.class, !className.isEmpty {
            parts.append(className)
        }
        if let align = gmcp.status?.align {
            parts.append("align \(align)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A compact horizontal vitals gauge: label, a proportional bar, and the
/// current value.
private struct VitalGauge: View {
    let label: String
    let current: Int
    let max: Int
    let tint: Color

    private let barWidth: CGFloat = 56

    var body: some View {
        let fraction = max > 0 ? Swift.max(0, Swift.min(1, Double(current) / Double(max))) : 0
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(tint)
            Capsule()
                .fill(.quaternary)
                .frame(width: barWidth, height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: barWidth * fraction, height: 5)
                }
            Text("\(current)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(label) \(current)/\(max)")
    }
}

private func previewGMCPState() -> GMCPState {
    var state = GMCPState()
    state.vitals = CharVitals(hp: 1500, mana: 900, moves: 1200)
    state.maxStats = CharMaxStats(maxhp: 2000, maxmana: 1500, maxmoves: 1400)
    state.status = CharStatus(level: 201, align: 1000)
    state.base = CharBase(name: "Tester", class: "Mage", race: "Human")
    return state
}

#Preview {
    VStack(spacing: 0) {
        Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
        StatusBarView(state: .connected, gmcp: previewGMCPState())
    }
    .frame(width: 700, height: 200)
}
