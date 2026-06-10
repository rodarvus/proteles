import MudCore
import SwiftUI

/// Detail editor for one ``CommandButton`` (Scripts ▸ Buttons). Binds live via
/// ``ScriptsModel/binding(forButton:)`` — every edit persists + re-mirrors.
struct CommandButtonEditor: View {
    @Binding var button: CommandButton

    /// Preset tints (avoids a Color↔hex round-trip); `nil` = the default accent.
    private static let tints: [(name: String, hex: String?)] = [
        ("Default", nil), ("Red", "#E5484D"), ("Orange", "#F76808"),
        ("Yellow", "#FFC53D"), ("Green", "#30A46C"), ("Blue", "#3E63DD"),
        ("Purple", "#8E4EC6"), ("Gray", "#8B8D98")
    ]

    var body: some View {
        Form {
            // The live preview is the panel's real tile view (D-106) — what
            // you style here is exactly what the command bar will show.
            Section("Preview") {
                HStack(spacing: 12) {
                    VStack(spacing: 2) {
                        CommandButtonCell(button: button, isOn: false) {}
                        if button.isToggle {
                            Text("off").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 180)
                    if button.isToggle {
                        VStack(spacing: 2) {
                            CommandButtonCell(button: button, isOn: true) {}
                            Text("on").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 180)
                    }
                }
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity)
            }

            Section("Button") {
                TextField("Label", text: $button.label)
                Picker("Action", selection: kind(for: \.action)) {
                    Text("Send command").tag(MacroActionKind.command)
                    Text("Run Lua script").tag(MacroActionKind.script)
                }
                CommandBodyEditor(
                    title: kind(for: \.action).wrappedValue == .script
                        ? "Script (Lua)" : "Command",
                    text: text(for: \.action)
                )
                if kind(for: \.action).wrappedValue == .command {
                    Text("Runs through aliases and ;-stacking, as if typed. "
                        + "Each line sends separately; ;; sends a literal ;.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Toggle") {
                Toggle("Two-state toggle", isOn: isToggle)
                if isToggle.wrappedValue {
                    Picker("Off action", selection: offKind) {
                        Text("Send command").tag(MacroActionKind.command)
                        Text("Run Lua script").tag(MacroActionKind.script)
                    }
                    CommandBodyEditor(
                        title: offKind.wrappedValue == .script
                            ? "Off script (Lua)" : "Off command",
                        text: offText
                    )
                    Text("On fires the action above; Off fires this. The panel tracks the state.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                tintSwatches
                ButtonSymbolPicker(symbol: $button.icon)
            }

            Section("Hotkey badge") {
                Toggle("Show a hotkey badge", isOn: showsHotkey)
                if showsHotkey.wrappedValue {
                    KeyChordRecorder(chord: hotkeyBinding)
                    Text("Display only — bind the real key in Macros.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(button.label.isEmpty ? "Button" : button.label)
    }

    // MARK: - Action bindings (reuse the Macro editor's kind/text helpers)

    private func kind(for keyPath: WritableKeyPath<CommandButton, MacroAction>) -> Binding<MacroActionKind> {
        Binding(
            get: { if case .script = button[keyPath: keyPath] { .script } else { .command } },
            set: { button[keyPath: keyPath] = MacroActionKind.make($0, text: button[keyPath: keyPath].text) }
        )
    }

    private func text(for keyPath: WritableKeyPath<CommandButton, MacroAction>) -> Binding<String> {
        Binding(
            get: { button[keyPath: keyPath].text },
            set: { button[keyPath: keyPath] = MacroActionKind.make(kind(for: keyPath).wrappedValue, text: $0)
            }
        )
    }

    // MARK: - Toggle bindings (the .toggle(off:) associated action)

    private var isToggle: Binding<Bool> {
        Binding(
            get: { button.isToggle },
            set: { button.kind = $0 ? .toggle(off: offAction) : .momentary }
        )
    }

    private var offAction: MacroAction {
        if case .toggle(let off) = button.kind { return off }
        return .command("")
    }

    private var offKind: Binding<MacroActionKind> {
        Binding(
            get: { if case .script = offAction { .script } else { .command } },
            set: { button.kind = .toggle(off: MacroActionKind.make($0, text: offAction.text)) }
        )
    }

    private var offText: Binding<String> {
        Binding(
            get: { offAction.text },
            set: { button.kind = .toggle(off: MacroActionKind.make(offKind.wrappedValue, text: $0)) }
        )
    }

    // MARK: - Appearance / hotkey bindings

    /// The tint as tappable colour swatches (a ring marks the selection) —
    /// glanceable like the Finder's tag colours, instead of a names-only menu.
    private var tintSwatches: some View {
        LabeledContent("Tint") {
            HStack(spacing: 8) {
                ForEach(Self.tints, id: \.hex) { tint in
                    Button {
                        button.tint = tint.hex
                    } label: {
                        Circle()
                            .fill(tint.hex.map { Color(hex: $0) } ?? Color.accentColor)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(
                                    .primary.opacity(button.tint == tint.hex ? 0.7 : 0),
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tint.name)
                    .accessibilityLabel("\(tint.name) tint")
                    .accessibilityAddTraits(button.tint == tint.hex ? .isSelected : [])
                }
            }
        }
    }

    private var showsHotkey: Binding<Bool> {
        Binding(
            get: { button.hotkeyEcho != nil },
            set: { button.hotkeyEcho = $0 ? (button.hotkeyEcho ?? KeyChord(keyCode: 0)) : nil }
        )
    }

    private var hotkeyBinding: Binding<KeyChord> {
        Binding(
            get: { button.hotkeyEcho ?? KeyChord(keyCode: 0) },
            set: { button.hotkeyEcho = $0 }
        )
    }
}
