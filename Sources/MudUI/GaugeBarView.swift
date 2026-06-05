import MudCore
import SwiftUI

/// Full-width graphical vitals bar that spans the bottom of the whole client
/// window (UI revamp — `docs/UI_REVAMP.md`). Mirrors Aardwolf's
/// `aard_health_bars_gmcp`: up to six wide bars — Health, Mana, Moves, TNL
/// (experience to next level), Enemy, and Alignment — sharing the width equally,
/// with a connection dot at the leading edge. Which bars show, their colours,
/// the number overlay, and the quarter marks all come from ``StatusBarConfig``.
/// The enemy bar is always present (greyed when not fighting), matching
/// MUSHclient. Each bar carries a left-aligned label and an optional
/// right-aligned number, both drawn with a contrasting outline so they stay
/// legible over any fill colour. The alignment marker is tier-coloured
/// (good/evil/neutral) with boundary ticks, not a single fill.
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
                        label: "Health",
                        current: vitals.hp,
                        max: max.maxhp,
                        tint: Color(hex: config.colors.health),
                        mode: config.numberMode,
                        showTicks: config.showTicks
                    )
                }
                if config.showMana {
                    WideGauge(
                        label: "Mana",
                        current: vitals.mana,
                        max: max.maxmana,
                        tint: Color(hex: config.colors.mana),
                        mode: config.numberMode,
                        showTicks: config.showTicks
                    )
                }
                if config.showMoves {
                    WideGauge(
                        label: "Moves",
                        current: vitals.moves,
                        max: max.maxmoves,
                        tint: Color(hex: config.colors.moves),
                        mode: config.numberMode,
                        showTicks: config.showTicks
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
    /// Without `perlevel` (not yet seen) it shows as a full bar carrying just the
    /// remaining count.
    @ViewBuilder private var tnlGauge: some View {
        let tnl = gmcp.status?.tnl ?? 0
        let perlevel = gmcp.base?.perlevel ?? 0
        WideGauge(
            label: "TNL",
            current: tnl,
            max: perlevel > 0 ? perlevel : tnl,
            tint: Color(hex: config.colors.tnl),
            mode: config.numberMode,
            showTicks: config.showTicks
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
                tint: Color(hex: config.colors.enemy),
                mode: config.numberMode,
                showTicks: config.showTicks
            )
        } else {
            WideGauge(
                label: "Enemy",
                current: 0,
                max: 100,
                tint: .gray.opacity(0.5),
                mode: .none,
                dimmed: true,
                showTicks: config.showTicks
            )
        }
    }

    /// Alignment marker on a good↔evil axis (not a fill): a track with a marker
    /// at `(align + 2500) / 5000`, **tier-coloured** (good = yellow, evil = red,
    /// neutral = grey), plus boundary ticks where alignment actually changes
    /// (±875). Greyed when no alignment has arrived.
    @ViewBuilder private var alignGauge: some View {
        if let align = gmcp.status?.align {
            let tint = switch StatusBarFormat.alignTier(align) {
            case .good: Color(rgb: 0xFFD000) // yellow
            case .evil: Color(rgb: 0xFF3333) // red
            case .neutral: Color(rgb: 0xCCCCCC) // grey
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

/// A wide proportional gauge filling the available width: a flat colour fill,
/// optional 25/50/75% quarter marks, a left-aligned outlined label, and an
/// optional right-aligned outlined number.
private struct WideGauge: View {
    let label: String
    let current: Int
    let max: Int
    let tint: Color
    let mode: StatusBarNumberMode
    var dimmed = false
    var showTicks = false

    private static let tickFractions: [Double] = [0.25, 0.5, 0.75]

    var body: some View {
        let fraction = StatusBarFormat.fraction(current: current, max: max)
        let overlayText = StatusBarFormat.overlay(mode: mode, current: current, max: max)
        ZStack {
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * fraction)
                if showTicks {
                    ForEach(Self.tickFractions, id: \.self) { mark in
                        Rectangle()
                            .fill(.black.opacity(0.3))
                            .frame(width: 1, height: geo.size.height)
                            .position(x: geo.size.width * mark, y: geo.size.height / 2)
                    }
                }
            }
            HStack(spacing: 4) {
                OutlinedText(label)
                Spacer(minLength: 4)
                if let overlayText {
                    OutlinedText(overlayText)
                }
            }
            .opacity(dimmed ? 0.6 : 1)
            .padding(.horizontal, 8)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .help(max > 0 ? "\(label) \(current)/\(max)" : label)
    }
}

/// The alignment bar: a track with a position marker (good↔evil), not a fill,
/// plus vertical boundary ticks where alignment tier actually changes (±875,
/// mirroring MUSHclient's `aard_health_bars_gmcp`).
private struct AlignGauge: View {
    let fraction: Double
    let tint: Color
    let overlay: String?

    /// Tier-change boundaries as bar fractions: align = ∓875 → (∓875+2500)/5000.
    private static let boundaryFractions: [Double] = [
        StatusBarFormat.alignFraction(-875),
        StatusBarFormat.alignFraction(875)
    ]

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                Rectangle()
                    .fill(tint.opacity(0.5))
                    .frame(height: 2)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                // Boundary ticks at the good/neutral/evil transitions.
                ForEach(Self.boundaryFractions, id: \.self) { mark in
                    Rectangle()
                        .fill(.black.opacity(0.4))
                        .frame(width: 1, height: geo.size.height)
                        .position(x: geo.size.width * mark, y: geo.size.height / 2)
                }
                // Position marker.
                Circle()
                    .fill(tint)
                    .frame(width: geo.size.height, height: geo.size.height)
                    .position(
                        x: Swift.max(
                            geo.size.height / 2,
                            Swift.min(geo.size.width - geo.size.height / 2, geo.size.width * fraction)
                        ),
                        y: geo.size.height / 2
                    )
            }
            HStack(spacing: 4) {
                OutlinedText("Alignment")
                Spacer(minLength: 4)
                if let overlay {
                    OutlinedText(overlay)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .help("Alignment")
    }
}

/// Text with a 1px contrasting contour, so it stays legible over any bar colour
/// (the "outline in the inverse colour" trick): white glyphs stamped with a
/// black outline at the eight surrounding offsets.
struct OutlinedText: View {
    let text: String
    var fill: Color = .white
    var outline: Color = .black

    init(_ text: String) {
        self.text = text
    }

    private static let offsets: [(x: CGFloat, y: CGFloat)] = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0), (1, 0),
        (-1, 1), (0, 1), (1, 1)
    ]

    var body: some View {
        ZStack {
            ForEach(Array(Self.offsets.enumerated()), id: \.offset) { _, point in
                Text(text).foregroundStyle(outline).offset(x: point.x, y: point.y)
            }
            Text(text).foregroundStyle(fill)
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
    }
}

public extension Color {
    /// Build a Color from a MudCore ``RGB`` (theme palette colour).
    init(_ rgb: RGB) {
        self = Color(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }

    /// Build a Color from a 0xRRGGBB literal.
    init(rgb: UInt32) {
        self = Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// Build a Color from a `#RRGGBB` (or `RRGGBB`) hex string; falls back to
    /// grey on a malformed value so a bad stored colour never crashes.
    init(hex: String) {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else {
            self = .gray
            return
        }
        self.init(rgb: value)
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
        GaugeBarView(
            state: .connected,
            gmcp: state,
            config: StatusBarConfig(numberMode: .number)
        )
    }
    .frame(width: 900, height: 160)
}
