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
///
/// Focus: the field auto-focuses on first appearance, and re-focuses
/// every time its window becomes **key** — ⌘-tabbing back to the app,
/// closing the Worlds window, or switching between the app's windows.
/// `controlActiveState` is per-window (unlike `scenePhase`, which is
/// app-wide and misses window-to-window transitions), so it's the
/// right signal for "the input should be ready to type into".
public struct CommandInputView: View {
    @State private var command: String = ""
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var controlActiveState
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
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: controlActiveState) { _, newState in
                if newState == .key { focused = true }
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
