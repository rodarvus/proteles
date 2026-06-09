import MudCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// What an `onMacroKey` handler did with a key chord.
public enum MacroKeyOutcome: Sendable, Equatable {
    /// Not a macro chord — let the keypress type normally.
    case notHandled
    /// A macro fired (send/script); swallow the keypress.
    case handled
    /// A `replace`-type macro: put this text in the command line (don't send)
    /// and swallow the keypress. The field sets its own text + caret.
    case replaceInput(String)
}

/// Command input field (auto-growing, multi-line capable).
///
/// On macOS this is an `NSTextField`-backed field (``CommandField``) so it
/// can intercept the keys SwiftUI's `TextField` swallows:
///
///   - **Tab / Shift-Tab → word completion.** Completes the *current word*
///     (the token ending at the caret) from the live ``CompletionVocabulary``
///     (room/group GMCP nouns, recent output words, command verbs/aliases),
///     replacing just that word and keeping the rest of the line. The first
///     Tab fills the best match; each further Tab cycles to the next, Shift-Tab
///     the previous. Mirrors Mudlet's `TCommandLine` tab completion.
///   - **Up / Down** walk the command history (``CommandHistory``), with
///     the partially-typed line preserved — applied only on the keypress,
///     never while typing.
///   - **Esc** cancels an in-progress completion cycle.
///   - **Enter** submits **exactly what's in the box** — nothing is ever
///     auto-completed or auto-accepted behind your back (a bare Enter sends an
///     empty line; MUDs use it to refresh prompts / page output). A multi-line
///     buffer sends **one command per line**.
///   - **Shift-Enter** inserts a newline instead of sending, and a pasted
///     multi-line string keeps its newlines — so you can compose or paste a
///     block of commands and send them in one Enter (#39). The field grows to
///     fit (up to a few lines) and shrinks back after sending.
///
/// The as-you-type ghost hint (#13) shows only on a single-line buffer (its
/// geometry tracks the caret on one row); a multi-line buffer hides it.
///
/// Focus: the field grabs first-responder on appear and whenever its
/// window becomes key (⌘-tabbing back, closing the Worlds window), matching
/// the previous `controlActiveState` behaviour.
///
/// Other platforms fall back to a plain SwiftUI `TextField` (there's no
/// hardware-keyboard story to support yet).
public struct CommandInputView: View {
    private let onSubmit: (String) -> Void
    private let onMacroKey: (@MainActor (KeyChord, _ inputIsEmpty: Bool) -> MacroKeyOutcome)?
    private let vocabulary: (@MainActor () -> CompletionVocabulary)?
    private let spellChecking: Bool
    private let ghostHint: Bool

    /// - Parameters:
    ///   - onSubmit: called with the line when the user presses Enter.
    ///   - onMacroKey: given a key chord (and whether the input is empty),
    ///     return `true` to indicate a macro consumed the keypress (the key is
    ///     then swallowed, not typed). Used for keypad/chord navigation.
    ///   - vocabulary: called on demand for the current completion vocabulary
    ///     (live GMCP nouns + recent output words + verbs/aliases). `nil`
    ///     disables word completion (only history recall remains).
    ///   - spellChecking: show red spell-check squiggles as you type (visual
    ///     only; never alters text). Auto-correct / smart quotes / dashes are
    ///     *always* disabled on the command line regardless — they'd silently
    ///     mangle commands like `cast 'armor'`.
    public init(
        onSubmit: @escaping (String) -> Void,
        onMacroKey: (@MainActor (KeyChord, _ inputIsEmpty: Bool) -> MacroKeyOutcome)? = nil,
        vocabulary: (@MainActor () -> CompletionVocabulary)? = nil,
        spellChecking: Bool = false,
        ghostHint: Bool = true
    ) {
        self.onSubmit = onSubmit
        self.onMacroKey = onMacroKey
        self.vocabulary = vocabulary
        self.spellChecking = spellChecking
        self.ghostHint = ghostHint
    }

    /// Live editor height (one line by default; grows as lines are added, up to
    /// ``CommandField/maxHeight``). Driven by the field editor's layout via the
    /// `onHeightChange` callback.
    @State private var fieldHeight: CGFloat = 20

    public var body: some View {
        CommandField(
            onSubmit: onSubmit,
            onMacroKey: onMacroKey,
            vocabulary: vocabulary,
            spellChecking: spellChecking,
            ghostHint: ghostHint,
            onHeightChange: { fieldHeight = $0 }
        )
        .frame(height: fieldHeight)
        .animation(.easeOut(duration: 0.1), value: fieldHeight)
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
        let onMacroKey: (@MainActor (KeyChord, Bool) -> MacroKeyOutcome)?
        let vocabulary: (@MainActor () -> CompletionVocabulary)?
        let spellChecking: Bool
        let ghostHint: Bool
        let onHeightChange: (CGFloat) -> Void

        /// One text line's height (set from the field's font in `makeNSView`).
        static let lineHeight: CGFloat = 20
        /// The tallest the input grows before it scrolls internally (~6 lines).
        static let maxHeight: CGFloat = 120

        func makeCoordinator() -> Coordinator {
            Coordinator(onSubmit: onSubmit, vocabulary: vocabulary)
        }

        /// A container holding the field plus a non-interactive grey "ghost" label
        /// drawn just after the caret. The ghost is never part of the editable
        /// text (so it can't be sent, can't eat the spacebar) — it's positioned
        /// over the empty area to the right of what's typed. #13 / D-96.
        func makeNSView(context: Context) -> NSView {
            let field = AutoFocusTextField()
            field.onMacroKey = onMacroKey
            field.spellChecking = spellChecking
            field.delegate = context.coordinator
            // Stable id so the output view can find + refocus the command field
            // when the user types after selecting text (always-focused input).
            field.identifier = NSUserInterfaceItemIdentifier("proteles.command")
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            // Multi-line capable (#39): wrap long lines and keep newlines (single-
            // line mode strips them on paste and makes Enter end editing). Enter
            // still *submits* — our `doCommandBy` intercepts `insertNewline:` and
            // only inserts a literal newline when Shift is held.
            field.lineBreakMode = .byWordWrapping
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.preferredMaxLayoutWidth = 0 // set from the live width by AppKit
            field.maximumNumberOfLines = 0

            let ghost = NSTextField(labelWithString: "")
            ghost.font = field.font
            ghost.textColor = .tertiaryLabelColor
            ghost.lineBreakMode = .byClipping
            ghost.isHidden = true
            ghost.refusesFirstResponder = true

            let container = NSView()
            field.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(field)
            container.addSubview(ghost) // on top, in the empty area after the caret
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                field.topAnchor.constraint(equalTo: container.topAnchor),
                field.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            context.coordinator.field = field
            context.coordinator.ghost = ghost
            context.coordinator.ghostHintEnabled = ghostHint
            context.coordinator.onHeightChange = onHeightChange
            context.coordinator.maxHeight = Self.maxHeight
            context.coordinator.minHeight = Self.lineHeight
            return container
        }

        func updateNSView(_: NSView, context: Context) {
            context.coordinator.onSubmit = onSubmit
            context.coordinator.vocabulary = vocabulary
            context.coordinator.ghostHintEnabled = ghostHint
            context.coordinator.onHeightChange = onHeightChange
            if let field = context.coordinator.field as? AutoFocusTextField {
                field.onMacroKey = onMacroKey
                field.spellChecking = spellChecking
                field.applyTextEditingPolicy() // re-apply if toggled while focused
            }
            if !ghostHint { context.coordinator.hideGhost() }
        }

        @MainActor
        final class Coordinator: NSObject, NSTextFieldDelegate {
            var onSubmit: (String) -> Void
            var vocabulary: (@MainActor () -> CompletionVocabulary)?
            weak var field: NSTextField?
            weak var ghost: NSTextField?
            /// As-you-type ghost hint on/off (the Settings toggle).
            var ghostHintEnabled = true
            /// Report the editor's desired height (#39 auto-grow).
            var onHeightChange: ((CGFloat) -> Void)?
            var minHeight: CGFloat = 20
            var maxHeight: CGFloat = 120
            private var lastReportedHeight: CGFloat = 20

            private var history = CommandHistory()

            /// Tab-completion cycle state: the full-line candidates for the
            /// current word (each = the text before the word + a completion),
            /// and the one currently shown. Built on the first Tab, cycled by
            /// repeated Tab / Shift-Tab, and cleared by any other key.
            private var candidates: [String] = []
            private var candidateIndex = 0
            private var cycling = false

            init(
                onSubmit: @escaping (String) -> Void,
                vocabulary: (@MainActor () -> CompletionVocabulary)?
            ) {
                self.onSubmit = onSubmit
                self.vocabulary = vocabulary
            }

            // MARK: - Typing

            /// Typing ends any Tab cycle and resets history navigation. We do
            /// **not** auto-suggest inline as you type — Enter always sends
            /// exactly what's in the box (no stale command fired by accident).
            func controlTextDidChange(_: Notification) {
                history.resetNavigation()
                cycling = false
                candidates = []
                updateGhost() // refresh the as-you-type hint for the new text
                updateHeight() // grow/shrink to fit the (possibly multi-line) text
            }

            func control(
                _: NSControl,
                textView _: NSTextView,
                doCommandBy commandSelector: Selector
            ) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                    return handleNewline(for: commandSelector)
                case #selector(NSResponder.moveUp(_:)):
                    endCycle()
                    if let text = history.recallPrevious(currentText: currentText) {
                        setText(text)
                    }
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    endCycle()
                    if let text = history.recallNext() {
                        setText(text)
                    }
                    return true
                case #selector(NSResponder.insertTab(_:)):
                    cycleCompletion(forward: true)
                    return true
                case #selector(NSResponder.insertBacktab(_:)):
                    cycleCompletion(forward: false)
                    return true
                case #selector(NSResponder.moveRight(_:)):
                    return acceptGhostOnRightArrow()
                case #selector(NSResponder.cancelOperation(_:)):
                    hideGhost()
                    return endCycle()
                default:
                    // Any other editing/navigation key ends the cycle and drops
                    // the ghost (the caret may have moved off the end); the field
                    // editor still handles the key normally. Real typing re-shows
                    // the ghost via controlTextDidChange.
                    cycling = false
                    candidates = []
                    hideGhost()
                    return false
                }
            }

            // MARK: - Actions

            /// Enter handling (#39): plain Enter submits the whole buffer;
            /// Shift-Enter (or `insertNewlineIgnoringFieldEditor:`, e.g.
            /// Option-Enter) inserts a literal newline instead.
            private func handleNewline(for selector: Selector) -> Bool {
                let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                let ignoresFieldEditor =
                    selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                if shiftHeld || ignoresFieldEditor {
                    insertNewlineIntoField()
                } else {
                    submit()
                }
                return true
            }

            private func submit() {
                let text = currentText
                // A multi-line buffer sends one command per line (#39); a plain
                // single line (incl. an empty one — MUDs use a bare Enter to
                // refresh the prompt) sends exactly itself.
                if text.contains("\n") {
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        onSubmit(String(line))
                    }
                } else {
                    onSubmit(text)
                }
                history.record(text)
                cycling = false
                candidates = []
                setText("")
            }

            /// Insert a literal newline at the caret (Shift-Enter), then refresh
            /// the auto-grow height. Goes through the field editor so undo and
            /// the caret position behave normally.
            private func insertNewlineIntoField() {
                guard let editor = field?.currentEditor() as? NSTextView else { return }
                editor.insertText("\n", replacementRange: editor.selectedRange)
                hideGhost()
                updateHeight()
            }

            /// Tab / Shift-Tab: complete the **current word** (the token ending
            /// at the caret) from the live vocabulary, replacing just that word
            /// and keeping the rest of the line. The first Tab fills the best
            /// match; each further Tab cycles to the next (Shift-Tab, previous).
            private func cycleCompletion(forward: Bool) {
                if !cycling {
                    guard let built = buildCandidates() else { return }
                    candidates = built
                    candidateIndex = forward ? 0 : built.count - 1
                    cycling = true
                } else {
                    guard !candidates.isEmpty else { return }
                    let count = candidates.count
                    candidateIndex = forward
                        ? (candidateIndex + 1) % count
                        : (candidateIndex - 1 + count) % count
                }
                setText(candidates[candidateIndex])
            }

            /// Full-line completion candidates for the word at the caret, or
            /// `nil` if there's no word to complete (caret after a space, empty
            /// line, no vocabulary, or no matches). Each candidate is the text
            /// before the word + a completed word, so the rest of the line is
            /// preserved.
            private func buildCandidates() -> [String]? {
                guard let vocabulary, caretIsAtEnd else { return nil }
                let line = currentText
                guard let (_, range) = InputCompletion.currentWord(in: line, caret: line.count)
                else { return nil }
                let words = vocabulary().completions(inLine: line, caret: line.count)
                guard !words.isEmpty else { return nil }
                let before = String(line[..<range.lowerBound])
                return words.map { before + $0 }
            }

            /// End any Tab cycle, leaving the field text as-is. Returns whether
            /// a cycle was active (so Esc can report it consumed the key).
            @discardableResult
            private func endCycle() -> Bool {
                guard cycling else { return false }
                cycling = false
                candidates = []
                return true
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

            /// Replace the field text and put the caret at the end. Programmatic
            /// edits don't fire `controlTextDidChange`, so this won't clobber
            /// cycle / navigation state.
            private func setText(_ text: String) {
                hideGhost() // every programmatic edit clears the hint
                let end = (text as NSString).length
                if let editor {
                    editor.string = text
                    editor.selectedRange = NSRange(location: end, length: 0)
                } else {
                    field?.stringValue = text
                }
                updateHeight() // history recall / completion may add or drop lines
            }

            // MARK: - Auto-grow height (#39)

            /// Report the editor's content height (clamped to one line … `maxHeight`)
            /// so the SwiftUI wrapper can grow/shrink the input bar. Uses the field
            /// editor's layout when present (accounts for soft-wrapped long lines),
            /// else falls back to one line. Only fires when the height changed.
            private func updateHeight() {
                let clamped = Swift.max(minHeight, Swift.min(measuredContentHeight(), maxHeight))
                guard abs(clamped - lastReportedHeight) > 0.5 else { return }
                lastReportedHeight = clamped
                onHeightChange?(clamped)
            }

            /// The field editor's laid-out text height (accounts for soft-wrapped
            /// long lines), or one line when there's no active editor.
            private func measuredContentHeight() -> CGFloat {
                guard let textView = field?.currentEditor() as? NSTextView,
                      let layoutManager = textView.layoutManager,
                      let container = textView.textContainer
                else { return minHeight }
                layoutManager.ensureLayout(for: container)
                return layoutManager.usedRect(for: container).height
            }

            // MARK: - As-you-type ghost hint (#13)

            func hideGhost() {
                ghost?.isHidden = true
            }

            /// Right-arrow at end-of-line accepts a shown ghost; otherwise it's a
            /// normal caret move (return false → the field editor handles it).
            private func acceptGhostOnRightArrow() -> Bool {
                guard ghost?.isHidden == false, caretIsAtEnd else {
                    hideGhost()
                    return false
                }
                acceptGhost()
                return true
            }

            /// Accept the ghost: fill the field with the best current-word
            /// completion (same as the first Tab), in the match's proper casing.
            private func acceptGhost() {
                guard let best = buildCandidates()?.first else { hideGhost(); return }
                setText(best) // setText hides the ghost
            }

            /// Recompute + position the grey hint after the caret, or hide it.
            /// Shows only when: enabled, the caret is at end-of-line, the current
            /// word has a completion, and there's room to the right of the caret.
            private func updateGhost() {
                guard ghostHintEnabled, let ghost, let field, let vocabulary, caretIsAtEnd else {
                    hideGhost(); return
                }
                let line = currentText
                // The ghost's geometry tracks the caret on a single row; skip it
                // entirely for a multi-line buffer (#39).
                guard !line.contains("\n") else { hideGhost(); return }
                guard !line.isEmpty,
                      let (word, _) = InputCompletion.currentWord(in: line, caret: line.count),
                      !word.isEmpty,
                      let suffix = vocabulary().ghostSuffix(inLine: line, caret: line.count),
                      let editor = field.currentEditor() as? NSTextView,
                      let container = ghost.superview, let window = container.window
                else { hideGhost(); return }
                // The caret rect (field-editor geometry → container coords) so the
                // hint sits exactly after the typed text, insets included.
                let caret = (line as NSString).length
                let screen = editor.firstRect(
                    forCharacterRange: NSRange(location: caret, length: 0),
                    actualRange: nil
                )
                let originX = container.convert(window.convertFromScreen(screen), from: nil).minX
                guard originX.isFinite, originX < container.bounds.maxX - 12 else { hideGhost(); return }
                ghost.stringValue = suffix
                let width = Swift.min(ghost.intrinsicContentSize.width, container.bounds.maxX - originX)
                ghost.frame = CGRect(
                    x: originX,
                    y: field.frame.minY,
                    width: width,
                    height: field.frame.height
                )
                ghost.isHidden = false
            }
        }
    }

    // `AutoFocusTextField` (the always-focused NSTextField subclass) lives in
    // CommandInputView+AutoFocusTextField.swift to keep this file under budget.

#else

    /// Fallback command field for platforms without AppKit (no hardware
    /// keyboard handling yet): a plain submit-and-clear text field. `onMacroKey`
    /// is accepted for API parity but unused (no key monitor off macOS).
    private struct CommandField: View {
        let onSubmit: (String) -> Void
        let onMacroKey: (@MainActor (KeyChord, Bool) -> MacroKeyOutcome)?
        var vocabulary: (@MainActor () -> CompletionVocabulary)?
        var spellChecking = false
        var ghostHint = true
        /// Accepted for API parity with the macOS field; the fallback is fixed-height.
        var onHeightChange: (CGFloat) -> Void = { _ in }
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
