import SwiftUI

/// Single-line command input field.
///
/// Phase 1: a plain SwiftUI `TextField` that submits on Enter and clears
/// after a successful submit. Command history and Up / Down recall land
/// alongside aliases in Phase 5 (PLAN.md §8.6); a richer
/// `NSTextField`-backed input arrives if/when keyboard macros need it.
///
/// Empty input (bare Enter) is sent through — MUDs use it to refresh
/// prompts, page through long output ("Press <RETURN> to continue"),
/// and confirm stateful sub-prompts. The wire result is a bare `\r\n`,
/// matching MUSHclient and Mudlet behaviour.
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
                onSubmit(command)
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
