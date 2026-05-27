import Foundation

/// Maps ``ANSIColor`` to a concrete ``RGB`` using a user-configurable
/// palette.
///
/// The eight base and eight bright named colours are stored explicitly.
/// 8-bit palette indices in 0…15 alias the named/brightNamed entries;
/// indices 16…231 are the 6×6×6 xterm RGB cube; 232…255 are 24 grays.
/// 24-bit RGB colours pass through unchanged.
///
/// PLAN.md §6.6 — additional palettes (Solarized, MUSHclient-default,
/// user-edited) ship in Phase 7 alongside the theme picker.
public struct ColorPalette: Sendable, Equatable, Codable {
    public let named: [NamedColor: RGB]
    public let brightNamed: [NamedColor: RGB]
    public let defaultForeground: RGB
    public let defaultBackground: RGB
    /// Minimum foreground/background contrast ratio (WCAG-style) to enforce, or
    /// `nil` for none. Light themes set this (~3) so MUD-sent near-white text —
    /// designed for a black background — doesn't vanish on a light one: any
    /// resolved foreground below the floor falls back to ``defaultForeground``
    /// (the theme's ink). The bit Mudlet/MUSHclient never did.
    public let minForegroundContrast: Double?

    public init(
        named: [NamedColor: RGB],
        brightNamed: [NamedColor: RGB],
        defaultForeground: RGB,
        defaultBackground: RGB,
        minForegroundContrast: Double? = nil
    ) {
        self.named = named
        self.brightNamed = brightNamed
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.minForegroundContrast = minForegroundContrast
    }

    /// Resolve an ``ANSIColor`` to its concrete ``RGB``.
    public func resolve(_ color: ANSIColor) -> RGB {
        switch color {
        case .named(let name):
            named[name] ?? defaultForeground
        case .brightNamed(let name):
            brightNamed[name] ?? defaultForeground
        case .palette(let index):
            resolvePalette(index)
        case .rgb(let red, let green, let blue):
            RGB(red, green, blue)
        }
    }

    /// Resolve an optional foreground colour, falling back to
    /// ``defaultForeground`` when `nil`, then applying the legibility clamp
    /// (light themes only — see ``minForegroundContrast``).
    public func resolveForeground(_ color: ANSIColor?) -> RGB {
        let resolved = color.map(resolve(_:)) ?? defaultForeground
        guard let floor = minForegroundContrast,
              Self.contrastRatio(resolved, defaultBackground) < floor
        else { return resolved }
        return defaultForeground
    }

    /// WCAG relative luminance of an sRGB colour (0…1).
    static func relativeLuminance(_ rgb: RGB) -> Double {
        func channel(_ value: UInt8) -> Double {
            let srgb = Double(value) / 255
            return srgb <= 0.03928 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
    }

    /// WCAG contrast ratio between two colours (1…21).
    static func contrastRatio(_ lhs: RGB, _ rhs: RGB) -> Double {
        let lumA = relativeLuminance(lhs), lumB = relativeLuminance(rhs)
        let (hi, lo) = lumA > lumB ? (lumA, lumB) : (lumB, lumA)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Resolve an optional background colour, falling back to
    /// ``defaultBackground`` when `nil`.
    public func resolveBackground(_ color: ANSIColor?) -> RGB {
        color.map(resolve(_:)) ?? defaultBackground
    }

    // MARK: - Private

    private func resolvePalette(_ index: UInt8) -> RGB {
        let value = Int(index)
        if value < 8 {
            let base = NamedColor(rawValue: UInt8(value))
            return base.flatMap { named[$0] } ?? defaultForeground
        }
        if value < 16 {
            let base = NamedColor(rawValue: UInt8(value - 8))
            return base.flatMap { brightNamed[$0] } ?? defaultForeground
        }
        if value >= 232 {
            // 24 levels of gray. xterm uses 8 + 10·n for n ∈ 0…23.
            let level = UInt8(8 + (value - 232) * 10)
            return RGB(level, level, level)
        }
        // 6×6×6 RGB cube. Standard xterm levels.
        let cubeIndex = value - 16
        let redIndex = (cubeIndex / 36) % 6
        let greenIndex = (cubeIndex / 6) % 6
        let blueIndex = cubeIndex % 6
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        return RGB(levels[redIndex], levels[greenIndex], levels[blueIndex])
    }
}

// MARK: - Presets

public extension ColorPalette {
    /// Default xterm RGB values for the 16 named colours, with a dark
    /// background and a near-white foreground. Used until the user
    /// picks a different palette in preferences.
    static let xtermDefault = ColorPalette(
        named: [
            .black: RGB(0, 0, 0),
            .red: RGB(205, 0, 0),
            .green: RGB(0, 205, 0),
            .yellow: RGB(205, 205, 0),
            .blue: RGB(0, 0, 238),
            .magenta: RGB(205, 0, 205),
            .cyan: RGB(0, 205, 205),
            .white: RGB(229, 229, 229)
        ],
        brightNamed: [
            .black: RGB(127, 127, 127),
            .red: RGB(255, 0, 0),
            .green: RGB(0, 255, 0),
            .yellow: RGB(255, 255, 0),
            .blue: RGB(92, 92, 255),
            .magenta: RGB(255, 0, 255),
            .cyan: RGB(0, 255, 255),
            .white: RGB(255, 255, 255)
        ],
        defaultForeground: RGB(229, 229, 229),
        defaultBackground: RGB(0, 0, 0)
    )
}
