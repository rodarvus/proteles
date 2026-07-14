import MudCore

#if os(macOS)
    import AppKit

    /// Container hook for width-driven soft-wrap recalculation.
    final class CommandInputContainerView: NSView {
        var onLayout: (() -> Void)?

        override func layout() {
            super.layout()
            onLayout?()
        }
    }

    private final class EventMonitorToken: @unchecked Sendable {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }
    }

    /// `NSTextView` that keeps the command line "always ready": it grabs
    /// first-responder on appear and whenever its window becomes key, and a
    /// window-scoped key monitor redirects stray typing back to it.
    final class AutoFocusCommandTextView: NSTextView {
        /// Local keyDown monitor that redirects typing to this view.
        private var keyMonitor: EventMonitorToken?

        /// Macro pre-filter: returns `true` if a bound macro consumed the key
        /// (so it's swallowed, not typed). See ``CommandInputView``.
        var onMacroKey: (@MainActor (KeyChord, Bool) -> MacroKeyOutcome)?

        /// Called for replace-input macros; the coordinator owns edit state.
        var replaceInput: ((String) -> Void)?

        /// Show spell-check squiggles as you type (visual only). Auto-correct
        /// and smart substitutions are always off (see ``applyTextEditingPolicy``).
        var spellChecking = false

        /// Lets the coordinator intercept Enter, Tab, history, completion, and Esc.
        var commandHandler: ((Selector) -> Bool)?

        /// Configure the command editor policy: never auto-correct or
        /// smart-substitute, because those silently rewrite MUD commands.
        func applyTextEditingPolicy() {
            isAutomaticQuoteSubstitutionEnabled = false
            isAutomaticDashSubstitutionEnabled = false
            isAutomaticTextReplacementEnabled = false
            isAutomaticSpellingCorrectionEnabled = false
            isGrammarCheckingEnabled = false
            isContinuousSpellCheckingEnabled = spellChecking
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
                if fireMacroIfMatch(event) { return nil }
                return redirect(event)
            }.map(EventMonitorToken.init)
        }

        override func doCommand(by selector: Selector) {
            if commandHandler?(selector) == true { return }
            super.doCommand(by: selector)
        }

        override func scrollPageUp(_ sender: Any?) {
            guard forwardPageCommand(#selector(NSResponder.scrollPageUp(_:)), sender: sender)
            else {
                super.scrollPageUp(sender)
                return
            }
        }

        override func scrollPageDown(_ sender: Any?) {
            guard forwardPageCommand(#selector(NSResponder.scrollPageDown(_:)), sender: sender)
            else {
                super.scrollPageDown(sender)
                return
            }
        }

        /// Offer `event` to the macro engine. Only keypresses aimed at our key
        /// window count (so key-capture in the Scripts editor is unaffected).
        private func fireMacroIfMatch(_ event: NSEvent) -> Bool {
            guard let onMacroKey, let window, window.isKeyWindow, event.window === window
            else { return false }
            switch onMacroKey(makeKeyChord(from: event), string.isEmpty) {
            case .notHandled:
                return false
            case .handled:
                return true
            case .replaceInput(let text):
                replaceInput?(text)
                return true
            }
        }

        @objc private func focusSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.isKeyWindow else { return }
                window.makeFirstResponder(self)
            }
        }

        /// If `event` is plain typing aimed at a non-text view in our key window,
        /// take focus and re-deliver it here; otherwise let it flow normally.
        private func redirect(_ event: NSEvent) -> NSEvent? {
            if shouldRedirectPaste(event) {
                window?.makeFirstResponder(self)
                NSApp.postEvent(event, atStart: true)
                return nil
            }
            guard let window, window.isKeyWindow, event.window === window,
                  window.firstResponder !== self,
                  !isTextEntry(window.firstResponder),
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option, .function]),
                  let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
                  scalar.value >= 0x20, scalar.value != 0x7F
            else { return event }
            window.makeFirstResponder(self)
            NSApp.postEvent(event, atStart: true)
            return nil
        }

        private func shouldRedirectPaste(_ event: NSEvent) -> Bool {
            guard let window, window.isKeyWindow, event.window === window,
                  window.firstResponder !== self,
                  !isTextEntry(window.firstResponder),
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  event.modifierFlags.contains(.command),
                  event.modifierFlags.isDisjoint(with: [.control, .option, .function])
            else { return false }
            return true
        }

        /// Whether `responder` is somewhere the user is legitimately typing.
        private func isTextEntry(_ responder: NSResponder?) -> Bool {
            guard let textView = responder as? NSTextView else { return false }
            return textView.isFieldEditor || textView.isEditable
        }

        private func forwardPageCommand(_ selector: Selector, sender: Any?) -> Bool {
            guard let output = window?.contentView?
                .firstDescendant(matching: "proteles.main-output")
            else { return false }
            return output.tryToPerform(selector, with: sender)
        }

        private func removeKeyMonitor() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor.value)
                self.keyMonitor = nil
            }
        }

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor.value)
            }
            NotificationCenter.default.removeObserver(self)
        }
    }

    private extension NSView {
        func firstDescendant(matching identifier: String) -> NSView? {
            for subview in subviews {
                if subview.identifier?.rawValue == identifier { return subview }
                if let found = subview.firstDescendant(matching: identifier) { return found }
            }
            return nil
        }
    }

#endif
