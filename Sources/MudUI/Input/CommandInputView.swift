import MudCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Single-line command input field.
///
/// On macOS this is an `NSTextField`-backed field (``CommandField``) so it
/// can intercept the keys SwiftUI's `TextField` swallows:
///
///   - **Up / Down** walk the command history (``CommandHistory``), with
///     the partially-typed line preserved.
///   - **Tab / Shift-Tab** cycle whole-line autocompletions drawn from
///     history (communication/chat commands are never offered); the
///     completed suffix is selected so the next keystroke replaces it.
///   - **Esc** cancels an in-progress completion, restoring what you typed.
///   - **Enter** submits (a bare Enter sends an empty line — MUDs use it
///     to refresh prompts / page output).
///
/// Focus: the field grabs first-responder on appear and whenever its
/// window becomes key (⌘-tabbing back, closing the Worlds window), matching
/// the previous `controlActiveState` behaviour.
///
/// Other platforms fall back to a plain SwiftUI `TextField` (there's no
/// hardware-keyboard story to support yet).
public struct CommandInputView: View {
    private let onSubmit: (String) -> Void

    public init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
    }

    public var body: some View {
        CommandField(onSubmit: onSubmit)
            .frame(height: 20)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
            }
    }
}

#if os(macOS)

    /// macOS command field. See ``CommandInputView`` for behaviour.
    private struct CommandField: NSViewRepresentable {
        let onSubmit: (String) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onSubmit: onSubmit)
        }

        func makeNSView(context: Context) -> NSTextField {
            let field = AutoFocusTextField()
            field.delegate = context.coordinator
            field.placeholderString = "Send command…"
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.lineBreakMode = .byClipping
            field.usesSingleLineMode = true
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            context.coordinator.field = field
            return field
        }

        func updateNSView(_: NSTextField, context: Context) {
            context.coordinator.onSubmit = onSubmit
        }

        @MainActor
        final class Coordinator: NSObject, NSTextFieldDelegate {
            var onSubmit: (String) -> Void
            weak var field: NSTextField?

            private var history = CommandHistory()

            // Tab-completion cycling state.
            private var completionPrefix = ""
            private var completionCandidates: [String] = []
            private var completionIndex = 0
            private var isCompleting = false

            init(onSubmit: @escaping (String) -> Void) {
                self.onSubmit = onSubmit
            }

            /// User typing invalidates history navigation and any completion.
            func controlTextDidChange(_: Notification) {
                history.resetNavigation()
                cancelCompletion()
            }

            func control(
                _: NSControl,
                textView _: NSTextView,
                doCommandBy commandSelector: Selector
            ) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.insertNewline(_:)):
                    submit()
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    cancelCompletion()
                    if let text = history.recallPrevious(currentText: currentText) {
                        setText(text)
                    }
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    cancelCompletion()
                    if let text = history.recallNext() {
                        setText(text)
                    }
                    return true
                case #selector(NSResponder.insertTab(_:)):
                    advanceCompletion(forward: true)
                    return true
                case #selector(NSResponder.insertBacktab(_:)):
                    advanceCompletion(forward: false)
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    return cancelCompletionIfActive()
                default:
                    return false
                }
            }

            // MARK: - Actions

            private func submit() {
                let text = currentText
                onSubmit(text)
                history.record(text)
                cancelCompletion()
                setText("")
            }

            private func advanceCompletion(forward: Bool) {
                if !isCompleting {
                    let candidates = history.completions(for: currentText)
                    guard !candidates.isEmpty else { return }
                    completionPrefix = currentText
                    completionCandidates = candidates
                    completionIndex = 0
                    isCompleting = true
                } else {
                    guard !completionCandidates.isEmpty else { return }
                    let count = completionCandidates.count
                    completionIndex = forward
                        ? (completionIndex + 1) % count
                        : (completionIndex - 1 + count) % count
                }
                applyCompletion(completionCandidates[completionIndex])
            }

            private func cancelCompletionIfActive() -> Bool {
                guard isCompleting else { return false }
                setText(completionPrefix)
                cancelCompletion()
                return true
            }

            private func cancelCompletion() {
                isCompleting = false
                completionCandidates = []
                completionIndex = 0
                completionPrefix = ""
            }

            // MARK: - Field text

            private var currentText: String {
                field?.stringValue ?? ""
            }

            /// Set the field text and place the caret at the end. Programmatic
            /// `stringValue` changes don't fire `controlTextDidChange`, so this
            /// won't clobber history-navigation or completion state.
            private func setText(_ text: String) {
                guard let field else { return }
                field.stringValue = text
                let end = (text as NSString).length
                field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
            }

            /// Apply a completion, selecting the auto-added suffix so the next
            /// keystroke replaces it (and Enter accepts the whole line).
            private func applyCompletion(_ text: String) {
                guard let field else { return }
                field.stringValue = text
                let prefixLength = (completionPrefix as NSString).length
                let fullLength = (text as NSString).length
                field.currentEditor()?.selectedRange = NSRange(
                    location: prefixLength,
                    length: max(0, fullLength - prefixLength)
                )
            }
        }
    }

    /// `NSTextField` that grabs first-responder on appear and whenever its
    /// window becomes key, so the command line is always ready to type into.
    private final class AutoFocusTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            guard let window else { return }
            focusSoon()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(focusSoon),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }

        @objc private func focusSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.isKeyWindow else { return }
                window.makeFirstResponder(self)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

#else

    /// Fallback command field for platforms without AppKit (no hardware
    /// keyboard handling yet): a plain submit-and-clear text field.
    private struct CommandField: View {
        let onSubmit: (String) -> Void
        @State private var command = ""
        @FocusState private var focused: Bool

        var body: some View {
            TextField("Command", text: $command, prompt: Text("Send command…"))
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

#Preview {
    VStack(spacing: 0) {
        Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
        CommandInputView { command in
            print("submit: \(command)")
        }
    }
    .frame(width: 600, height: 200)
}
