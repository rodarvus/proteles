import MudCore
import MudUI
import SwiftUI

/// A compact sample of game output rendered through a theme's palette + font.
struct ThemePreview: View {
    let theme: Theme
    let fontSize: Double
    let fontName: String

    private var font: Font {
        fontName.isEmpty
            ? .system(size: fontSize, design: .monospaced)
            : .custom(fontName, fixedSize: fontSize)
    }

    var body: some View {
        let palette = theme.palette
        VStack(alignment: .leading, spacing: 1) {
            Text("Twisted Mind of a Psionicist")
                .foregroundStyle(Color(palette.brightNamed[.cyan] ?? palette.defaultForeground))
            Text("[ Exits: north east south ]")
                .foregroundStyle(Color(palette.brightNamed[.green] ?? palette.defaultForeground))
            Text("A psionicist ").foregroundStyle(Color(palette.defaultForeground))
                + Text("(White Aura)")
                .foregroundStyle(Color(palette.brightNamed[.white] ?? palette.defaultForeground))
                + Text(" floats here.").foregroundStyle(Color(palette.defaultForeground))
            Text("3004hp ")
                .foregroundStyle(Color(palette.brightNamed[.red] ?? palette.defaultForeground))
                + Text("2458mn ")
                .foregroundStyle(Color(palette.brightNamed[.blue] ?? palette.defaultForeground))
                + Text("1686mv")
                .foregroundStyle(Color(palette.brightNamed[.green] ?? palette.defaultForeground))
            Text("@x017 and @x232 stay readable on dark themes")
                .foregroundStyle(Color(palette.resolveForeground(.palette(17))))
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(palette.defaultBackground), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
    }
}

struct ThemePaletteGrid: View {
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                colorChip("Text", theme.palette.defaultForeground)
                colorChip("Background", theme.palette.defaultBackground)
            }
            ansiRow(title: "Normal", colors: theme.palette.named)
            ansiRow(title: "Bright", colors: theme.palette.brightNamed)
        }
    }

    private func ansiRow(title: String, colors: [NamedColor: RGB]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(NamedColor.allCases, id: \.self) { name in
                    colorChip(name.label, colors[name] ?? theme.palette.defaultForeground)
                }
            }
        }
    }

    private func colorChip(_ label: String, _ rgb: RGB) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(rgb))
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
            Text(label)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(rgb.hexString)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .help("\(label) \(rgb.hexString)")
    }
}

private extension NamedColor {
    var label: String {
        switch self {
        case .black: "Black"
        case .red: "Red"
        case .green: "Green"
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .magenta: "Magenta"
        case .cyan: "Cyan"
        case .white: "White"
        }
    }
}
