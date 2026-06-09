import MudCore
import SwiftUI

/// Detail editor for one ``Macro``. Binds live through
/// ``ScriptsModel/binding(forMacro:)``.
struct MacroEditorView: View {
    @Binding var macro: Macro

    var body: some View {
        Form {
            Section("Key") {
                KeyChordRecorder(chord: $macro.chord)
                if let hint = tierHint {
                    Label(hint, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Action") {
                Picker("Type", selection: actionKind) {
                    Text("Send command").tag(MacroActionKind.command)
                    Text("Replace command line").tag(MacroActionKind.replaceInput)
                    Text("Run Lua script").tag(MacroActionKind.script)
                }
                TextField(
                    actionKind.wrappedValue == .script ? "Script (Lua)" : "Command",
                    text: actionText,
                    axis: .vertical
                )
                .font(.body.monospaced())
                .lineLimit(1...10)
            }

            Section("Options") {
                Toggle("Enabled", isOn: $macro.enabled)
                TextField("Name", text: $macro.name.orEmpty())
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
    }

    private var title: String {
        if let name = macro.name, !name.isEmpty { return name }
        return KeyChordFormatter.describe(macro.chord)
    }

    /// A one-line note about how/when this chord fires, or `nil` when there's
    /// nothing surprising (a keypad/modifier/function chord that always fires).
    private var tierHint: String? {
        guard macro.chord.keyCode != 0 || !macro.chord.modifiers.isEmpty else {
            return "Click “Record Key”, then press the key to bind."
        }
        switch MacroEngine.tier(for: macro.chord) {
        case .bare:
            return "Bare keys fire only in Navigation Mode while the command line is empty."
        case .chord, .keypad:
            return nil
        }
    }

    private var actionKind: Binding<MacroActionKind> {
        Binding(
            get: {
                switch macro.action {
                case .command: .command
                case .script: .script
                case .replaceInput: .replaceInput
                }
            },
            set: { macro.action = MacroActionKind.make($0, text: macro.action.text) }
        )
    }

    private var actionText: Binding<String> {
        Binding(
            get: { macro.action.text },
            set: { macro.action = MacroActionKind.make(actionKind.wrappedValue, text: $0) }
        )
    }
}

/// The selectable kinds of ``MacroAction`` (the editor's type picker).
enum MacroActionKind: String, CaseIterable, Identifiable {
    case command, replaceInput, script

    var id: String {
        rawValue
    }

    /// Rebuild an action from a kind and its text (preserving the text when the
    /// user flips the picker).
    static func make(_ kind: MacroActionKind, text: String) -> MacroAction {
        switch kind {
        case .command: .command(text)
        case .replaceInput: .replaceInput(text)
        case .script: .script(text)
        }
    }
}

extension MacroAction {
    /// The action's text payload (the command, script source, or prefill text).
    var text: String {
        switch self {
        case .command(let value), .script(let value), .replaceInput(let value): value
        }
    }
}
