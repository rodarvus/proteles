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
/// On macOS this is an `NSTextView`-backed field (``CommandField``) so it
/// can wrap, scroll, and intercept the keys SwiftUI's `TextField` swallows:
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
    private let autoRepeatLastCommand: Bool

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
        ghostHint: Bool = true,
        autoRepeatLastCommand: Bool = false
    ) {
        self.onSubmit = onSubmit
        self.onMacroKey = onMacroKey
        self.vocabulary = vocabulary
        self.spellChecking = spellChecking
        self.ghostHint = ghostHint
        self.autoRepeatLastCommand = autoRepeatLastCommand
    }

    /// Live editor height (one line by default; grows as lines are added, up to
    /// ``CommandField/maxHeight``). Driven by the text view's own layout via the
    /// `onHeightChange` callback.
    @State private var fieldHeight: CGFloat = 20

    public var body: some View {
        CommandField(
            onSubmit: onSubmit,
            onMacroKey: onMacroKey,
            vocabulary: vocabulary,
            spellChecking: spellChecking,
            ghostHint: ghostHint,
            autoRepeatLastCommand: autoRepeatLastCommand,
            onHeightChange: { fieldHeight = $0 }
        )
        .frame(height: fieldHeight)
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
    struct CommandField: NSViewRepresentable {
        let onSubmit: (String) -> Void
        let onMacroKey: (@MainActor (KeyChord, Bool) -> MacroKeyOutcome)?
        let vocabulary: (@MainActor () -> CompletionVocabulary)?
        let spellChecking: Bool
        let ghostHint: Bool
        let autoRepeatLastCommand: Bool
        let onHeightChange: (CGFloat) -> Void

        /// The input grows to five visual rows; beyond that the text view scrolls.
        static let visualLineCap: CGFloat = 5
        static let textInset = NSSize(width: 0, height: 2)

        func makeCoordinator() -> Coordinator {
            Coordinator(onSubmit: onSubmit, vocabulary: vocabulary)
        }

        /// A container holding the field plus a non-interactive grey "ghost" label
        /// drawn just after the caret. The ghost is never part of the editable
        /// text (so it can't be sent, can't eat the spacebar) — it's positioned
        /// over the empty area to the right of what's typed. #13 / D-96.
        func makeNSView(context: Context) -> NSView {
            let scrollView = makeScrollView()
            let textView = makeTextView(context: context)
            let ghost = makeGhostLabel(font: textView.font)
            let container = makeContainer(scrollView: scrollView, ghost: ghost, context: context)
            scrollView.documentView = textView
            configureCoordinator(
                context.coordinator,
                container: container,
                scrollView: scrollView,
                textView: textView,
                ghost: ghost
            )
            DispatchQueue.main.async { context.coordinator.updateHeight() }
            return container
        }

        static func lineHeight(for font: NSFont?) -> CGFloat {
            guard let font else { return 20 }
            return ceil(font.ascender - font.descender + font.leading)
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            var onSubmit: (String) -> Void
            var vocabulary: (@MainActor () -> CompletionVocabulary)?
            weak var container: NSView?
            weak var scrollView: NSScrollView?
            weak var textView: AutoFocusCommandTextView?
            weak var ghost: NSTextField?
            /// As-you-type ghost hint on/off (the Settings toggle).
            var ghostHintEnabled = true
            /// Opt-in: a bare Enter on an empty line resends the last command
            /// (MUSHclient `auto_repeat`). Off by default — see ``submit()``.
            var autoRepeatLastCommand = false
            /// Report the editor's desired height (#39 auto-grow).
            var onHeightChange: ((CGFloat) -> Void)?
            var lineHeight: CGFloat = 20
            var maxVisualLines: CGFloat = 5
            private var lastReportedHeight: CGFloat = 0
            private var programmaticEdit = false

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
            func textDidChange(_: Notification) {
                guard !programmaticEdit else { return }
                history.resetNavigation()
                cycling = false
                candidates = []
                updateHeight() // grow/shrink to fit the (possibly multi-line) text
                resetScrollIfAllContentFits()
                scrollCaretToVisible()
                updateGhost() // refresh the as-you-type hint for the new text
            }

            func handleCommand(_ commandSelector: Selector) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                    return handleNewline(for: commandSelector)
                case #selector(NSResponder.moveUp(_:)):
                    return handleMoveUp()
                case #selector(NSResponder.moveDown(_:)):
                    return handleMoveDown()
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

            private func handleMoveUp() -> Bool {
                endCycle()
                guard caretIsOnFirstVisualLine else { hideGhost(); return false }
                if let text = history.recallPrevious(currentText: currentText) {
                    setText(text)
                }
                return true
            }

            private func handleMoveDown() -> Bool {
                endCycle()
                guard caretIsOnLastVisualLine else { hideGhost(); return false }
                if let text = history.recallNext() {
                    setText(text)
                }
                return true
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
                history.record(text)
                cycling = false
                candidates = []
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
                // Auto-repeat (opt-in, MUSHclient `auto_repeat` / Mudlet keep-on-
                // send): instead of clearing, keep the just-sent command in the
                // box, fully selected — so a bare Enter resends it and typing
                // replaces it. Empty and multi-line sends clear as usual (an empty
                // line stays empty — never "repeat from nothing").
                if autoRepeatLastCommand, !text.isEmpty, !text.contains("\n") {
                    setText(text, selectAll: true)
                } else {
                    setText("")
                }
            }

            /// Insert a literal newline at the caret (Shift-Enter), then refresh
            /// the auto-grow height. Goes through the field editor so undo and
            /// the caret position behave normally.
            private func insertNewlineIntoField() {
                guard let textView else { return }
                textView.insertText("\n", replacementRange: textView.selectedRange())
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

            private var currentText: String {
                textView?.string ?? ""
            }

            private var caretIsAtEnd: Bool {
                guard let range = textView?.selectedRange() else { return true }
                return range.length == 0
                    && range.location == (currentText as NSString).length
            }

            private var caretIsOnFirstVisualLine: Bool {
                visualLinePosition?.isFirst ?? true
            }

            private var caretIsOnLastVisualLine: Bool {
                visualLinePosition?.isLast ?? true
            }

            private var visualLinePosition: (isFirst: Bool, isLast: Bool)? {
                guard let textView,
                      textView.selectedRange().length == 0,
                      let layoutManager = textView.layoutManager,
                      let container = textView.textContainer
                else { return nil }
                let characterCount = (currentText as NSString).length
                guard characterCount > 0 else { return (true, true) }
                layoutManager.ensureLayout(for: container)
                let glyphCount = layoutManager.numberOfGlyphs
                guard glyphCount > 0 else { return (true, true) }
                let caret = Swift.min(textView.selectedRange().location, characterCount)
                let characterIndex = Swift.max(0, Swift.min(caret, characterCount - 1))
                let glyphIndex = Swift.min(
                    layoutManager.glyphIndexForCharacter(at: characterIndex),
                    glyphCount - 1
                )
                var lineRange = NSRange()
                _ = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
                return (lineRange.location == 0, NSMaxRange(lineRange) >= glyphCount)
            }

            /// Replace the field text and put the caret at the end. Programmatic
            /// edits don't fire `controlTextDidChange`, so this won't clobber
            /// cycle / navigation state.
            private func setText(_ text: String, selectAll: Bool = false) {
                guard let textView else { return }
                hideGhost() // every programmatic edit clears the hint
                let end = (text as NSString).length
                programmaticEdit = true
                textView.string = text
                // Auto-repeat keeps the just-sent command *selected* (MUSHclient
                // SetSel(0,-1) / Mudlet selectAll) so Enter resends it and typing
                // replaces it; otherwise the caret sits at the end.
                textView.setSelectedRange(
                    selectAll ? NSRange(location: 0, length: end) : NSRange(location: end, length: 0)
                )
                programmaticEdit = false
                updateHeight() // history recall / completion may add or drop lines
                resetScrollIfAllContentFits()
                scrollCaretToVisible()
                DispatchQueue.main.async { [weak self] in
                    self?.resetScrollIfAllContentFits()
                    self?.scrollCaretToVisible()
                }
            }

            func replaceInput(_ text: String) {
                endCycle()
                history.resetNavigation()
                setText(text)
            }

            // MARK: - Auto-grow height (#39)

            /// Report the editor's content height (clamped to one line … `maxHeight`)
            /// so the SwiftUI wrapper can grow/shrink the input bar. Uses this
            /// text view's layout, so soft-wrapped long lines are measured directly.
            func updateHeight() {
                guard let scrollView else { return }
                updateTextContainerWidth()
                let contentHeight = measuredContentHeight()
                let minHeight = lineHeight + CommandField.textInset.height * 2
                let maxHeight = lineHeight * maxVisualLines + CommandField.textInset.height * 2
                let clamped = Swift.max(minHeight, Swift.min(contentHeight, maxHeight))
                scrollView.hasVerticalScroller = contentHeight > maxHeight + 0.5
                guard abs(clamped - lastReportedHeight) > 0.5 else { return }
                lastReportedHeight = clamped
                onHeightChange?(clamped)
            }

            /// The text view's laid-out content height, including vertical inset.
            private func measuredContentHeight() -> CGFloat {
                measuredTextHeight() + CommandField.textInset.height * 2
            }

            private func measuredTextHeight() -> CGFloat {
                guard let textView,
                      let layoutManager = textView.layoutManager,
                      let container = textView.textContainer
                else { return lineHeight }
                layoutManager.ensureLayout(for: container)
                return Swift.max(lineHeight, ceil(layoutManager.usedRect(for: container).height))
            }

            private func updateTextContainerWidth() {
                guard let textView, let scrollView, let container = textView.textContainer else { return }
                let width = Swift.max(1, scrollView.contentView.bounds.width)
                container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                if abs(textView.frame.width - width) > 0.5 {
                    textView.frame.size.width = width
                }
                let height = Swift.max(measuredContentHeight(), scrollView.contentView.bounds.height)
                if abs(textView.frame.height - height) > 0.5 {
                    textView.frame.size.height = height
                }
            }

            private func scrollCaretToVisible() {
                guard let textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
            }

            private func resetScrollIfAllContentFits() {
                guard let scrollView else { return }
                let contentHeight = measuredContentHeight()
                guard contentHeight <= scrollView.contentView.bounds.height + 0.5 else { return }
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
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
                guard ghostHintEnabled, let ghost, let textView, let vocabulary, caretIsAtEnd else {
                    hideGhost(); return
                }
                let line = currentText
                // The ghost's geometry tracks the caret on a single row; skip it
                // for explicit newlines and soft-wrapped long lines (#39/#71).
                guard !line.contains("\n"), measuredTextHeight() <= lineHeight + 1 else {
                    hideGhost(); return
                }
                guard !line.isEmpty,
                      let (word, _) = InputCompletion.currentWord(in: line, caret: line.count),
                      !word.isEmpty,
                      let suffix = vocabulary().ghostSuffix(inLine: line, caret: line.count),
                      let container = ghost.superview, let window = container.window
                else { hideGhost(); return }
                // The caret rect (text-view geometry → container coords) so the
                // hint sits exactly after the typed text, insets included.
                let caret = (line as NSString).length
                let screen = textView.firstRect(
                    forCharacterRange: NSRange(location: caret, length: 0),
                    actualRange: nil
                )
                let caretRect = container.convert(window.convertFromScreen(screen), from: nil)
                let originX = caretRect.minX
                guard originX.isFinite, originX < container.bounds.maxX - 12 else { hideGhost(); return }
                ghost.font = textView.font
                ghost.stringValue = suffix
                let width = Swift.min(ghost.intrinsicContentSize.width, container.bounds.maxX - originX)
                let height = Swift.max(ghost.intrinsicContentSize.height, lineHeight)
                let originY = caretRect.midY - height / 2
                ghost.frame = CGRect(
                    x: originX,
                    y: originY,
                    width: width,
                    height: height
                )
                ghost.isHidden = false
            }
        }
    }

    // `AutoFocusCommandTextView` (the always-focused NSTextView subclass) lives
    // in CommandInputView+AutoFocusTextField.swift to keep this file under budget.

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
