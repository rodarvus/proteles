import MudCore
import SwiftUI

/// Full-width graphical vitals bar that spans the bottom of the whole client
/// window (UI revamp — `docs/UI_REVAMP.md`). Mirrors Aardwolf's
/// `aard_health_bars_gmcp`: up to six wide bars — Health, Mana, Moves, TNL
/// (experience to next level), Enemy, and Alignment — sharing the width equally,
/// with a connection dot at the leading edge. Which bars show and how their
/// numbers are overlaid come from ``StatusBarConfig``. The enemy bar is always
/// present (greyed when not fighting), matching MUSHclient.
public struct GaugeBarView: View {
    private let state: StatusBarView.ConnectionState
    private let gmcp: GMCPState
    private let config: StatusBarConfig

    public init(
        state: StatusBarView.ConnectionState,
        gmcp: GMCPState,
        config: StatusBarConfig = StatusBarConfig()
    ) {
        self.state = state
        self.gmcp = gmcp
        self.config = config
    }

    /// MUSHclient `aard_health_bars_gmcp` default bar colours (read as RGB).
    private enum BarColor {
        static let health = Color(rgb: 0x00FF00) // green
        static let mana = Color(rgb: 0xFF5500) // orange
        static let moves = Color(rgb: 0x00FFFF) // cyan
        static let tnl = Color(rgb: 0xFFFFFF) // white
        static let enemy = Color(rgb: 0x0000FF) // blue
        static let alignEvil = Color(rgb: 0x0000FF) // blue
        static let alignGood = Color(rgb: 0x00FFFF) // cyan
        static let alignNeutral = Color(rgb: 0xCCCCCC) // grey
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .help(connectionLabel)

            if config.isEmpty {
                Spacer()
            } else if let vitals = gmcp.vitals, let max = gmcp.maxStats {
                if config.showHealth {
                    WideGauge(
                        label: "HP",
                        current: vitals.hp,
                        max: max.maxhp,
                        tint: BarColor.health,
                        mode: config.numberMode
                    )
                }
                if config.showMana {
                    WideGauge(
                        label: "MP",
                        current: vitals.mana,
                        max: max.maxmana,
                        tint: BarColor.mana,
                        mode: config.numberMode
                    )
                }
                if config.showMoves {
                    WideGauge(
                        label: "MV",
                        current: vitals.moves,
                        max: max.maxmoves,
                        tint: BarColor.moves,
                        mode: config.numberMode
                    )
                }
                if config.showTNL { tnlGauge }
                if config.showEnemy { enemyGauge }
                if config.showAlign { alignGauge }
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

    /// Experience to next level: `char.status.tnl` out of `char.base.perlevel`.
    /// Without `perlevel` (not yet seen) it shows as a full white bar carrying
    /// just the remaining count.
    @ViewBuilder private var tnlGauge: some View {
        let tnl = gmcp.status?.tnl ?? 0
        let perlevel = gmcp.base?.perlevel ?? 0
        WideGauge(
            label: "XP",
            current: tnl,
            max: perlevel > 0 ? perlevel : tnl,
            tint: BarColor.tnl,
            mode: config.numberMode
        )
    }

    /// Enemy health — always shown; greyed/empty when not in combat (MUSHclient
    /// parity, the "greyed out" idle state).
    @ViewBuilder private var enemyGauge: some View {
        if let target = gmcp.status?.combatTarget {
            WideGauge(
                label: target.name,
                current: target.percent,
                max: 100,
                tint: BarColor.enemy,
                mode: config.numberMode
            )
        } else {
            WideGauge(
                label: "Enemy",
                current: 0,
                max: 100,
                tint: .gray.opacity(0.5),
                mode: .none,
                dimmed: true
            )
        }
    }

    /// Alignment marker on a good↔evil axis (not a fill): a track with a marker
    /// at `(align + 2500) / 5000`, coloured by tier. Greyed when no alignment.
    @ViewBuilder private var alignGauge: some View {
        if let align = gmcp.status?.align {
            let tier = StatusBarFormat.alignTier(align)
            let tint = switch tier {
            case .evil: BarColor.alignEvil
            case .good: BarColor.alignGood
            case .neutral: BarColor.alignNeutral
            }
            AlignGauge(
                fraction: StatusBarFormat.alignFraction(align),
                tint: tint,
                overlay: config.numberMode == .none ? nil : "\(align)"
            )
        } else {
            AlignGauge(fraction: 0.5, tint: .gray.opacity(0.5), overlay: nil)
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

/// A wide proportional gauge filling the available width, with the label and an
/// optional number overlay (none / raw value / percentage).
private struct WideGauge: View {
    let label: String
    let current: Int
    let max: Int
    let tint: Color
    let mode: StatusBarNumberMode
    var dimmed = false

    var body: some View {
        let fraction = StatusBarFormat.fraction(current: current, max: max)
        let overlayText = StatusBarFormat.overlay(mode: mode, current: current, max: max)
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
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let overlayText {
                    Text(overlayText)
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(.white.opacity(dimmed ? 0.5 : 0.92))
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .padding(.horizontal, 8)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .help(max > 0 ? "\(label) \(current)/\(max)" : label)
    }
}

/// The alignment bar: a track with a position marker (good↔evil), not a fill.
private struct AlignGauge: View {
    let fraction: Double
    let tint: Color
    let overlay: String?

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                // Axis line across the middle.
                Rectangle()
                    .fill(tint.opacity(0.5))
                    .frame(height: 2)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                // Position marker.
                Circle()
                    .fill(tint.gradient)
                    .frame(width: geo.size.height, height: geo.size.height)
                    .position(
                        x: Swift.max(
                            geo.size.height / 2,
                            Swift.min(
                                geo.size.width - geo.size.height / 2,
                                geo.size.width * fraction
                            )
                        ),
                        y: geo.size.height / 2
                    )
            }
            HStack(spacing: 4) {
                Text("Align")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let overlay {
                    Text(overlay)
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .padding(.horizontal, 8)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .help("Alignment")
    }
}

private extension Color {
    /// Build a Color from a 0xRRGGBB literal.
    init(rgb: UInt32) {
        self = Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

#Preview {
    var state = GMCPState()
    state.vitals = CharVitals(hp: 1500, mana: 700, moves: 1100)
    state.maxStats = CharMaxStats(maxhp: 2000, maxmana: 1500, maxmoves: 1400)
    state.status = CharStatus(level: 201, tnl: 3010, align: 1000)
    state.base = CharBase(name: "Tester", class: "Mage", perlevel: 12000)
    return VStack(spacing: 0) {
        Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
        GaugeBarView(state: .connected, gmcp: state)
    }
    .frame(width: 900, height: 160)
}
