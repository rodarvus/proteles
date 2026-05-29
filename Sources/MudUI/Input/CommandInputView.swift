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
///     empty line; MUDs use it to refresh prompts / page output).
///
/// Focus: the field grabs first-responder on appear and whenever its
/// window becomes key (⌘-tabbing back, closing the Worlds window), matching
/// the previous `controlActiveState` behaviour.
///
/// Other platforms fall back to a plain SwiftUI `TextField` (there's no
/// hardware-keyboard story to support yet).
public struct CommandInputView: View {
    private let onSubmit: (String) -> Void
    private let onMacroKey: (@MainActor (KeyChord, _ inputIsEmpty: Bool) -> Bool)?
    private let vocabulary: (@MainActor () -> CompletionVocabulary)?
    private let spellChecking: Bool

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
        onMacroKey: (@MainActor (KeyChord, _ inputIsEmpty: Bool) -> Bool)? = nil,
        vocabulary: (@MainActor () -> CompletionVocabulary)? = nil,
        spellChecking: Bool = false
    ) {
        self.onSubmit = onSubmit
        self.onMacroKey = onMacroKey
        self.vocabulary = vocabulary
        self.spellChecking = spellChecking
    }

    public var body: some View {
        CommandField(
            onSubmit: onSubmit,
            onMacroKey: onMacroKey,
            vocabulary: vocabulary,
            spellChecking: spellChecking
        )
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
        let onMacroKey: (@MainActor (KeyChord, Bool) -> Bool)?
        let vocabulary: (@MainActor () -> CompletionVocabulary)?
        let spellChecking: Bool

        func makeCoordinator() -> Coordinator {
            Coordinator(onSubmit: onSubmit, vocabulary: vocabulary)
        }

        func makeNSView(context: Context) -> NSTextField {
            let field = AutoFocusTextField()
            field.onMacroKey = onMacroKey
            field.spellChecking = spellChecking
            field.delegate = context.coordinator
            // Stable id so the output view can find + refocus the command field
            // when the user types after selecting text (always-focused input).
            field.identifier = NSUserInterfaceItemIdentifier("proteles.command")
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

        func updateNSView(_ nsView: NSTextField, context: Context) {
            context.coordinator.onSubmit = onSubmit
            context.coordinator.vocabulary = vocabulary
            (nsView as? AutoFocusTextField)?.onMacroKey = onMacroKey
            if let field = nsView as? AutoFocusTextField {
                field.spellChecking = spellChecking
                field.applyTextEditingPolicy() // re-apply if toggled while focused
            }
        }

        @MainActor
        final class Coordinator: NSObject, NSTextFieldDelegate {
            var onSubmit: (String) -> Void
            var vocabulary: (@MainActor () -> CompletionVocabulary)?
            weak var field: NSTextField?

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
                case #selector(NSResponder.cancelOperation(_:)):
                    return endCycle()
                default:
                    // Any other editing/navigation key ends the cycle but is
                    // otherwise handled normally by the field editor.
                    cycling = false
                    candidates = []
                    return false
                }
            }

            // MARK: - Actions

            private func submit() {
                let text = currentText
                onSubmit(text)
                history.record(text)
                cycling = false
                candidates = []
                setText("")
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
                guard let (word, range) = InputCompletion.currentWord(in: line, caret: line.count)
                else { return nil }
                let isFirst = InputCompletion.isFirstWord(in: line, caret: line.count)
                let words = vocabulary().completions(forWord: word, isFirstWord: isFirst)
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
                let end = (text as NSString).length
                if let editor {
                    editor.string = text
                    editor.selectedRange = NSRange(location: end, length: 0)
                } else {
                    field?.stringValue = text
                }
            }
        }
    }

    /// `NSTextField` that keeps the command line "always ready": it grabs
    /// first-responder on appear and whenever its window becomes key, and a
    /// window-scoped key monitor redirects stray typing back to it. So after
    /// selecting output text, clicking the map / target list / channels, etc.,
    /// the next printable key snaps focus here and is typed — no mouse needed.
    private final class AutoFocusTextField: NSTextField {
        /// Local keyDown monitor that redirects typing to this field. Held so we
        /// can remove it when the field leaves its window.
        private var keyMonitor: Any?

        /// Macro pre-filter: returns `true` if a bound macro consumed the key
        /// (so it's swallowed, not typed). See ``CommandInputView``.
        var onMacroKey: (@MainActor (KeyChord, Bool) -> Bool)?

        /// Show spell-check squiggles as you type (visual only). Auto-correct
        /// and smart substitutions are always off (see ``applyTextEditingPolicy``).
        var spellChecking = false

        /// Configure the (shared) field editor for a *command* line: never
        /// auto-correct or smart-substitute (those silently rewrite commands —
        /// e.g. smart quotes turn `cast 'armor'` into curly quotes the MUD
        /// won't parse), and toggle continuous spell-checking per the setting.
        /// Re-applied whenever we take focus or the setting changes, because the
        /// window's field editor is shared and reused across fields.
        func applyTextEditingPolicy() {
            guard let editor = currentEditor() as? NSTextView else { return }
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isContinuousSpellCheckingEnabled = spellChecking
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { applyTextEditingPolicy() }
            return became
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            removeKeyMonitor()
            guard let window else { return }
            focusSoon()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(focusSoon),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // A bound macro (keypad/modifier/function chord, or a bare key
                // in Navigation mode) consumes the key before it's typed.
                if fireMacroIfMatch(event) { return nil }
                return redirect(event)
            }
        }

        /// Offer `event` to the macro engine. Only keypresses aimed at our key
        /// window count (so key-capture in the Scripts editor is unaffected).
        /// The engine decides whether the chord fires given the input state.
        private func fireMacroIfMatch(_ event: NSEvent) -> Bool {
            guard let onMacroKey, let window, window.isKeyWindow, event.window === window
            else { return false }
            return onMacroKey(makeKeyChord(from: event), currentInputText.isEmpty)
        }

        /// The live text in the command line (the field editor's contents while
        /// editing, else the field value).
        private var currentInputText: String {
            currentEditor()?.string ?? stringValue
        }

        @objc private func focusSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.isKeyWindow else { return }
                window.makeFirstResponder(self)
            }
        }

        /// If `event` is plain typing aimed at a non-text view in our (key)
        /// window, take focus and re-deliver it here; returns nil to swallow the
        /// original. Otherwise returns the event untouched so it flows normally
        /// (typing in this field, any other text field, ⌘-shortcuts, nav keys).
        private func redirect(_ event: NSEvent) -> NSEvent? {
            guard let window, window.isKeyWindow, event.window === window,
                  window.firstResponder !== self,
                  window.firstResponder !== currentEditor(),
                  !isTextEntry(window.firstResponder),
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option, .function]),
                  let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
                  scalar.value >= 0x20, scalar.value != 0x7F // not a control/delete char
            else { return event }
            window.makeFirstResponder(self)
            NSApp.postEvent(event, atStart: true)
            return nil
        }

        /// Whether `responder` is somewhere the user is legitimately typing — a
        /// field editor or an editable text view — which we must not disturb.
        private func isTextEntry(_ responder: NSResponder?) -> Bool {
            guard let textView = responder as? NSTextView else { return false }
            return textView.isFieldEditor || textView.isEditable
        }

        private func removeKeyMonitor() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

#else

    /// Fallback command field for platforms without AppKit (no hardware
    /// keyboard handling yet): a plain submit-and-clear text field. `onMacroKey`
    /// is accepted for API parity but unused (no key monitor off macOS).
    private struct CommandField: View {
        let onSubmit: (String) -> Void
        let onMacroKey: (@MainActor (KeyChord, Bool) -> Bool)?
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
