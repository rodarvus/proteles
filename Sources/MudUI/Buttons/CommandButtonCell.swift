import MudCore
import SwiftUI

/// One command-button tile: icon + label (+ a hotkey-echo badge), tinted; a
/// toggle fills solid when on. Shared by the command-bar panel and the
/// button editor's live preview (D-106) — the preview renders *this* view,
/// so what you style is exactly what the bar shows.
/// A button's icon: an SF Symbol when the string names one, else the text
/// itself (so an emoji — or any glyph — works as an icon too).
struct ButtonIconView: View {
    let icon: String

    var body: some View {
        if Self.isSymbolName(icon) {
            Image(systemName: icon)
        } else {
            Text(icon)
        }
    }

    /// Whether the platform knows `name` as an SF Symbol.
    static func isSymbolName(_ name: String) -> Bool {
        #if os(macOS)
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
            UIImage(systemName: name) != nil
        #endif
    }
}

struct CommandButtonCell: View {
    let button: CommandButton
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = button.icon, !icon.isEmpty {
                    ButtonIconView(icon: icon)
                }
                Text(button.label).lineLimit(1).truncationMode(.tail)
                if let chord = button.hotkeyEcho {
                    Text(KeyChordFormatter.describe(chord))
                        .font(.caption2)
                        .foregroundStyle(filled ? .white.opacity(0.8) : .secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                filled ? tint.opacity(0.9) : tint.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(filled ? .white : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(0.4), lineWidth: filled ? 0 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(button.isToggle ? "\(button.label) (toggle)" : button.label)
    }

    /// A toggle that's on draws solid; momentary + toggle-off draw tinted-light.
    private var filled: Bool {
        button.isToggle && isOn
    }

    private var tint: Color {
        button.tint.map { Color(hex: $0) } ?? .accentColor
    }
}
