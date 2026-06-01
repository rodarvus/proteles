import Foundation

// Pure, UI-agnostic model for the bottom vitals bars (the graphical readout
// `GaugeBarView` renders). Kept in MudCore so the per-bar visibility, the
// number-overlay formatting, and the alignment-bar maths are unit-testable
// without SwiftUI. Mirrors the bar set + behaviour of Aardwolf's
// `aard_health_bars_gmcp`: Health, Mana, Moves, TNL, Enemy, Align.

/// How the numeric value is overlaid on a bar.
public enum StatusBarNumberMode: String, Sendable, CaseIterable, Codable {
    /// Graphical bar only — no overlaid text (the default).
    case none
    /// The raw current value, e.g. `2093`.
    case number
    /// The percentage of max, e.g. `84%`.
    case percentage
}

/// Which of the six bars are shown + how their numbers are displayed. Drives
/// ``GaugeBarView``; persisted in the app via `@AppStorage` (one key per field).
public struct StatusBarConfig: Sendable, Equatable {
    public var showHealth: Bool
    public var showMana: Bool
    public var showMoves: Bool
    public var showTNL: Bool
    public var showEnemy: Bool
    public var showAlign: Bool
    public var numberMode: StatusBarNumberMode
    /// Draw 25/50/75% quarter marks on the five fill bars (HP/MP/MV/TNL/Enemy).
    /// The alignment bar has its own axis and is unaffected.
    public var showTicks: Bool
    /// Per-bar colours as `#RRGGBB` hex (user-pickable, persisted). Kept as
    /// strings here so MudCore stays UI-agnostic; the renderer parses them.
    public var colors: StatusBarColors

    public init(
        showHealth: Bool = true,
        showMana: Bool = true,
        showMoves: Bool = true,
        showTNL: Bool = true,
        showEnemy: Bool = true,
        showAlign: Bool = true,
        numberMode: StatusBarNumberMode = .none,
        showTicks: Bool = true,
        colors: StatusBarColors = StatusBarColors()
    ) {
        self.showHealth = showHealth
        self.showMana = showMana
        self.showMoves = showMoves
        self.showTNL = showTNL
        self.showEnemy = showEnemy
        self.showAlign = showAlign
        self.numberMode = numberMode
        self.showTicks = showTicks
        self.colors = colors
    }

    /// True when no bar is enabled — the whole bar row can then be hidden.
    public var isEmpty: Bool {
        !(showHealth || showMana || showMoves || showTNL || showEnemy || showAlign)
    }
}

/// Per-bar colours as `#RRGGBB` hex strings, for the five fill bars (HP/MP/MV/
/// TNL/Enemy). Defaults match the user's MUSHclient profile (Moves = `#FFFF00`,
/// read from the saved `showBar` state) with HP a touch darker by request. The
/// alignment bar is **not** here — its marker is tier-coloured (good/evil/
/// neutral), not a single user-pickable colour. Users override each via a
/// colour picker.
public struct StatusBarColors: Sendable, Equatable {
    public var health: String
    public var mana: String
    public var moves: String
    public var tnl: String
    public var enemy: String

    public init(
        health: String = "#00C000",
        mana: String = "#2E6FFF",
        moves: String = "#FFFF00",
        tnl: String = "#CCCCCC",
        enemy: String = "#FF3333"
    ) {
        self.health = health
        self.mana = mana
        self.moves = moves
        self.tnl = tnl
        self.enemy = enemy
    }
}

/// Pure helpers for rendering a bar's value + the alignment marker.
public enum StatusBarFormat {
    /// The overlay text for a `current`/`max` bar under `mode`, or `nil` when no
    /// text should be drawn (`.none`, or a non-positive `max` for a percentage).
    public static func overlay(mode: StatusBarNumberMode, current: Int, max: Int) -> String? {
        switch mode {
        case .none:
            return nil
        case .number:
            return "\(current)"
        case .percentage:
            guard max > 0 else { return nil }
            let pct = Int((Double(current) / Double(max) * 100).rounded())
            return "\(Swift.max(0, Swift.min(100, pct)))%"
        }
    }

    /// The proportional fill (0…1) for a `current`/`max` bar, clamped.
    public static func fraction(current: Int, max: Int) -> Double {
        guard max > 0 else { return 0 }
        return Swift.max(0, Swift.min(1, Double(current) / Double(max)))
    }

    // MARK: - Alignment bar

    /// Where the alignment marker sits on the bar, 0…1 (left = most evil, right
    /// = most angelic). Aardwolf alignment runs roughly -2500…2500; the
    /// reference bar maps it as `(align + 2500) / 5000` (see
    /// `aard_health_bars_gmcp`'s `DoSpecialBar_Align`). Clamped.
    public static func alignFraction(_ align: Int) -> Double {
        Swift.max(0, Swift.min(1, Double(align + 2500) / 5000))
    }

    /// Good/neutral/evil tier for the alignment marker's colour. The reference's
    /// boundaries: `zeroed = align + 2500`; evil ≤ 1625 (align ≤ -875),
    /// good ≥ 3375 (align ≥ 875), neutral in between.
    public enum AlignTier: Sendable, Equatable { case evil, neutral, good }

    public static func alignTier(_ align: Int) -> AlignTier {
        let zeroed = align + 2500
        if zeroed <= 1625 { return .evil }
        if zeroed >= 3375 { return .good }
        return .neutral
    }
}
