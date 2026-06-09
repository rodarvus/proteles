import MudCore
import SwiftUI

#if os(macOS)
    import AppKit

    /// `NSTextField` that keeps the command line "always ready": it grabs
    /// first-responder on appear and whenever its window becomes key, and a
    /// window-scoped key monitor redirects stray typing back to it. So after
    /// selecting output text, clicking the map / target list / channels, etc.,
    /// the next printable key snaps focus here and is typed — no mouse needed.
    ///
    /// Split out of ``CommandInputView`` to keep that file under the 600-line
    /// budget; `internal` (not `private`) so the file's `CommandField` can use it.
    final class AutoFocusTextField: NSTextField {
        /// Local keyDown monitor that redirects typing to this field. Held so we
        /// can remove it when the field leaves its window.
        private var keyMonitor: Any?

        /// Macro pre-filter: returns `true` if a bound macro consumed the key
        /// (so it's swallowed, not typed). See ``CommandInputView``.
        var onMacroKey: (@MainActor (KeyChord, Bool) -> MacroKeyOutcome)?

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
            switch onMacroKey(makeKeyChord(from: event), currentInputText.isEmpty) {
            case .notHandled:
                return false
            case .handled:
                return true
            case .replaceInput(let text):
                setCommandLine(text)
                return true
            }
        }

        /// Put `text` in the command line (without sending) + caret at the end —
        /// a `replace`-type macro. The field owns its text, so no binding round-
        /// trip is needed.
        private func setCommandLine(_ text: String) {
            stringValue = text
            if let editor = currentEditor() {
                editor.string = text
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
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

#endif
