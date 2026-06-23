import SwiftUI

#if !os(macOS)
    /// Fallback command field for platforms without AppKit (no hardware
    /// keyboard handling yet): a plain submit-and-clear text field. `onMacroKey`
    /// is accepted for API parity but unused (no key monitor off macOS).
    struct CommandField: View {
        let onSubmit: (String) -> Void
        let onSubmitBatch: ([String]) -> Void
        let onMacroKey: (@MainActor (KeyChord, Bool) -> MacroKeyOutcome)?
        var vocabulary: (@MainActor () -> CompletionVocabulary)?
        var spellChecking = false
        var ghostHint = true
        /// Accepted for API parity with the macOS field; the fallback is fixed-height.
        var onHeightChange: (CGFloat) -> Void = { _ in }
        @State private var command = ""
        @FocusState private var focused: Bool

        var body: some View {
            TextField("Command", text: $command, prompt: Text("Send command..."))
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit {
                    onSubmit(command)
                    command = ""
                }
        }
    }
#endif
