import MudCore
import SwiftUI

/// The Keypad tab (D-102): the numeric keypad drawn as it sits under the
/// hand — an Apple-keyboard-shaped grid of keycaps — instead of MUSHclient's
/// column of text fields. Click a key, type its command below; bound keys
/// read their command right on the cap, so the whole layout is one glance.
/// Keypad Enter is shown but not bindable (it submits the command line).
struct KeypadEditorView: View {
    @Bindable var model: ScriptsModel
    @State private var selectedKey: KeypadKey?
    @FocusState private var commandFieldFocused: Bool

    private static let keyWidth: CGFloat = 72
    private static let keyHeight: CGFloat = 52
    private static let gap: CGFloat = 8

    /// The left three columns of the Apple keypad, row by row; the fourth
    /// column (`* - + ⏎`) and the wide `0` are laid out separately.
    private static let leftRows: [[KeypadKey]] = [
        [.clear, .equals, .divide],
        [.num7, .num8, .num9],
        [.num4, .num5, .num6],
        [.num1, .num2, .num3]
    ]
    private static let rightColumn: [KeypadKey] = [.multiply, .subtract, .add]

    var body: some View {
        VStack(spacing: 24) {
            Toggle("Enable keypad commands", isOn: enabledBinding)
                .toggleStyle(.switch)
            keypadGrid
                .opacity(model.keypad.enabled ? 1 : 0.5)
            commandEditor
            Text("Keypad commands run through aliases, just like typed input. "
                + "A macro bound to the same key takes precedence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private var keypadGrid: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            VStack(spacing: Self.gap) {
                ForEach(Self.leftRows, id: \.self) { row in
                    HStack(spacing: Self.gap) {
                        ForEach(row, id: \.self) { key in
                            keycap(key)
                        }
                    }
                }
                HStack(spacing: Self.gap) {
                    keycap(.num0, width: Self.keyWidth * 2 + Self.gap)
                    keycap(.decimal)
                }
            }
            VStack(spacing: Self.gap) {
                ForEach(Self.rightColumn, id: \.self) { key in
                    keycap(key)
                }
                enterCap
            }
        }
    }

    private func keycap(_ key: KeypadKey, width: CGFloat = keyWidth) -> some View {
        let command = model.keypad.command(for: key)
        return Button {
            selectedKey = key
            commandFieldFocused = true
        } label: {
            VStack(spacing: 2) {
                Text(Self.symbol(key))
                    .font(.body.weight(.medium))
                if let command, !command.isEmpty {
                    Text(command)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                }
            }
            .frame(width: width, height: Self.keyHeight)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(command == nil ? AnyShapeStyle(.quinary) : AnyShapeStyle(.quaternary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        selectedKey == key ? Color.accentColor : .clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
        .help(command.map { "Keypad \(Self.symbol(key)) sends “\($0)”" }
            ?? "Keypad \(Self.symbol(key)) — unbound")
        .accessibilityLabel("Keypad \(Self.accessibilityName(key))")
        .accessibilityValue(command ?? "unbound")
    }

    /// Keypad Enter: drawn in place (tall, like the physical key) but not a
    /// binding target — it submits the command line.
    private var enterCap: some View {
        VStack(spacing: 2) {
            Text("⏎")
                .font(.body.weight(.medium))
            Text("sends")
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .frame(width: Self.keyWidth, height: Self.keyHeight * 2 + Self.gap)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quinary))
        .help("Keypad Enter submits the command line — not bindable.")
        .accessibilityHidden(true)
    }

    // MARK: - Command editor

    @ViewBuilder
    private var commandEditor: some View {
        if let key = selectedKey {
            HStack(spacing: 8) {
                Text("Keypad \(Self.symbol(key))")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 86, alignment: .trailing)
                TextField(
                    "Command",
                    text: commandBinding(for: key),
                    prompt: Text("Command to send")
                )
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(maxWidth: 320)
                .focused($commandFieldFocused)
                .onSubmit {
                    // Return commits and closes the editor row — the binding
                    // already saved every keystroke, so this is pure dismissal.
                    commandFieldFocused = false
                    selectedKey = nil
                }
            }
        } else {
            Text("Select a key to set the command it sends.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { [weak model] in model?.keypad.enabled ?? true },
            set: { [weak model] enabled in
                Task { @MainActor in await model?.setKeypadEnabled(enabled) }
            }
        )
    }

    private func commandBinding(for key: KeypadKey) -> Binding<String> {
        Binding(
            get: { [weak model] in model?.keypad.command(for: key) ?? "" },
            set: { [weak model] command in
                Task { @MainActor in await model?.setKeypadCommand(command, for: key) }
            }
        )
    }

    // MARK: - Labels

    private static let symbols: [KeypadKey: String] = [
        .num0: "0", .num1: "1", .num2: "2", .num3: "3", .num4: "4",
        .num5: "5", .num6: "6", .num7: "7", .num8: "8", .num9: "9",
        .divide: "/", .multiply: "*", .subtract: "-", .add: "+",
        .decimal: ".", .clear: "⌧", .equals: "="
    ]

    private static func symbol(_ key: KeypadKey) -> String {
        symbols[key] ?? "?"
    }

    private static func accessibilityName(_ key: KeypadKey) -> String {
        switch key {
        case .divide: "divide"
        case .multiply: "multiply"
        case .subtract: "minus"
        case .add: "plus"
        case .decimal: "decimal point"
        case .clear: "clear"
        case .equals: "equals"
        default: symbol(key)
        }
    }
}
