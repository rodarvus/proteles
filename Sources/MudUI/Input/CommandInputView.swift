import SwiftUI

/// Single-line command input field.
///
/// Phase 1: a plain SwiftUI `TextField` that submits on Enter and clears
/// after a successful submit. Command history and Up / Down recall land
/// alongside aliases in Phase 5 (PLAN.md §8.6); a richer
/// `NSTextField`-backed input arrives if/when keyboard macros need it.
///
/// Whitespace-only input is swallowed (matches MUSHclient behaviour:
/// hitting Enter on an empty line should not send `\r\n` to the server).
public struct CommandInputView: View {
    @State private var command: String = ""
    private let onSubmit: (String) -> Void

    public init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
    }

    public var body: some View {
        TextField("Command", text: $command, prompt: Text("Send command…"))
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
            }
            .onSubmit {
                let trimmed = command
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onSubmit(trimmed)
                command = ""
            }
    }
}

#Preview {
    VStack(spacing: 0) {
        Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
        CommandInputView { command in
            print("submit: \(command)")
        }
    }
    .frame(width: 600, height: 200)
}
