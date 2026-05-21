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
///   - **Type-ahead.** As you type, the most-recently-used matching command
///     from history is shown inline with its completed suffix selected, so
///     a bare **Enter** accepts the whole line. Deleting never re-suggests.
///     Communication/chat commands are never offered.
///   - **Tab / Shift-Tab** cycle to the next/previous matching command.
///   - **Up / Down** walk the command history (``CommandHistory``), with
///     the partially-typed line preserved.
///   - **Esc** dismisses the inline suggestion, restoring what you typed;
///     **→ / End** accepts it in place so you can keep editing.
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

            /// The user-typed prefix the current inline suggestion is based
            /// on (the text *before* the auto-completed, selected suffix).
            private var typedPrefix = ""

            /// Length of the typed text at the previous change, used to tell
            /// an insertion (suggest) from a deletion (don't).
            private var previousTypedLength = 0

            /// LRU-ordered completion candidates for ``typedPrefix`` and the
            /// one currently shown. Tab / Shift-Tab cycle through them.
            private var candidates: [String] = []
            private var candidateIndex = 0
            private var suggesting = false

            init(onSubmit: @escaping (String) -> Void) {
                self.onSubmit = onSubmit
            }

            // MARK: - Typing → inline suggestion

            /// As the user types, offer the most-recent matching command
            /// inline with the completed suffix selected, so a bare Enter
            /// accepts it. Deletions never trigger a suggestion (otherwise
            /// Backspace would just re-expand).
            func controlTextDidChange(_: Notification) {
                history.resetNavigation()
                clearSuggestion()

                let full = currentText
                let isInsertion = full.count > previousTypedLength
                typedPrefix = full
                previousTypedLength = full.count

                guard isInsertion, !full.isEmpty, caretIsAtEnd else { return }
                let matches = history.completions(for: full)
                guard !matches.isEmpty else { return }
                candidates = matches
                candidateIndex = 0
                suggesting = true
                showCandidate()
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
                    revertSuggestion()
                    if let text = history.recallPrevious(currentText: currentText) {
                        setText(text)
                    }
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    revertSuggestion()
                    if let text = history.recallNext() {
                        setText(text)
                    }
                    return true
                case #selector(NSResponder.insertTab(_:)):
                    cycleCandidate(forward: true)
                    return true
                case #selector(NSResponder.insertBacktab(_:)):
                    cycleCandidate(forward: false)
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    return revertSuggestionIfActive()
                case #selector(NSResponder.moveRight(_:)),
                     #selector(NSResponder.moveToEndOfLine(_:)),
                     #selector(NSResponder.moveToEndOfParagraph(_:)):
                    // Accept the inline suggestion in place (caret to end)
                    // without sending; keep typing-vs-deleting bookkeeping
                    // honest by treating the whole line as "typed".
                    acceptSuggestionInPlace()
                    return false
                default:
                    return false
                }
            }

            // MARK: - Actions

            private func submit() {
                let text = currentText
                onSubmit(text)
                history.record(text)
                clearSuggestion()
                typedPrefix = ""
                previousTypedLength = 0
                setText("")
            }

            /// Tab / Shift-Tab: cycle to the next/previous completion for the
            /// typed prefix. Starts a suggestion if none is showing yet.
            private func cycleCandidate(forward: Bool) {
                if !suggesting {
                    let prefix = currentText
                    let matches = history.completions(for: prefix)
                    guard !matches.isEmpty else { return }
                    typedPrefix = prefix
                    candidates = matches
                    candidateIndex = 0
                    suggesting = true
                } else {
                    guard !candidates.isEmpty else { return }
                    let count = candidates.count
                    candidateIndex = forward
                        ? (candidateIndex + 1) % count
                        : (candidateIndex - 1 + count) % count
                }
                showCandidate()
            }

            private func revertSuggestionIfActive() -> Bool {
                guard suggesting else { return false }
                revertSuggestion()
                return true
            }

            /// Drop the suggestion and restore what the user actually typed.
            private func revertSuggestion() {
                guard suggesting else { return }
                clearSuggestion()
                setText(typedPrefix)
            }

            /// Keep the shown suggestion in the line as accepted text.
            private func acceptSuggestionInPlace() {
                guard suggesting else { return }
                clearSuggestion()
                typedPrefix = currentText
                previousTypedLength = currentText.count
            }

            private func clearSuggestion() {
                suggesting = false
                candidates = []
                candidateIndex = 0
            }

            // MARK: - Field text

            private var editor: NSText? {
                field?.currentEditor()
            }

            private var currentText: String {
                editor?.string ?? field?.stringValue ?? ""
            }

            private var caretIsAtEnd: Bool {
                guard let range = editor?.selectedRange else { return true }
                return range.length == 0
                    && range.location == (currentText as NSString).length
            }

            /// Replace the field text and put the caret at the end.
            /// Programmatic edits don't fire `controlTextDidChange`, so this
            /// won't clobber navigation/suggestion state.
            private func setText(_ text: String) {
                let end = (text as NSString).length
                if let editor {
                    editor.string = text
                    editor.selectedRange = NSRange(location: end, length: 0)
                } else {
                    field?.stringValue = text
                }
                typedPrefix = text
                previousTypedLength = text.count
            }

            /// Show ``candidates``[``candidateIndex``] with the suffix beyond
            /// ``typedPrefix`` selected, so the next keystroke replaces it and
            /// Enter accepts the whole line.
            private func showCandidate() {
                guard let editor, candidates.indices.contains(candidateIndex) else { return }
                let text = candidates[candidateIndex]
                editor.string = text
                let prefixLength = (typedPrefix as NSString).length
                let fullLength = (text as NSString).length
                editor.selectedRange = NSRange(
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
