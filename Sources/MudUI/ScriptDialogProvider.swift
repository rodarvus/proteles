#if os(macOS)
    import AppKit
    import MudCore

    /// The app's native `utils.*` dialog provider. Each request runs as a modal
    /// on the main thread and returns **synchronously** — the calling plugin's
    /// Lua blocks on the result (MUSHclient's dialogs are modal too). The command
    /// path that triggers a dialog is async, so the main thread is free to run
    /// the modal while the script executor waits; no deadlock.
    public func makeScriptDialogProvider() -> ScriptDialogProvider {
        { request in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { ScriptDialogRunner.run(request) }
            }
            return DispatchQueue.main.sync { MainActor.assumeIsolated { ScriptDialogRunner.run(request) } }
        }
    }

    @MainActor
    enum ScriptDialogRunner {
        static func run(_ request: ScriptDialog) -> ScriptDialogResult {
            switch request {
            case .message(let text, let title, let buttons): message(text, title, buttons)
            case .input(let prompt, let title, let def, let multiline): input(prompt, title, def, multiline)
            case .choose(let prompt, let title, let items): choose(prompt, title, items)
            case .openFile(let message, let dir): openFile(message, dir)
            }
        }

        /// MUSHclient button codes → (button title, returned label), default first.
        private static func buttonSet(_ code: Int) -> [(title: String, label: String)] {
            switch code {
            case 1: [("OK", "ok"), ("Cancel", "cancel")]
            case 3: [("Yes", "yes"), ("No", "no"), ("Cancel", "cancel")]
            case 4: [("Yes", "yes"), ("No", "no")]
            default: [("OK", "ok")]
            }
        }

        private static func message(_ text: String, _ title: String, _ buttons: Int) -> ScriptDialogResult {
            let alert = NSAlert()
            alert.messageText = title.isEmpty ? text : title
            if !title.isEmpty { alert.informativeText = text }
            let set = buttonSet(buttons)
            for button in set {
                alert.addButton(withTitle: button.title)
            }
            let chosen = Int(alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn
                .rawValue)
            return .button(set.indices.contains(chosen) ? set[chosen].label : set[0].label)
        }

        private static func input(
            _ prompt: String, _ title: String, _ def: String, _ multiline: Bool
        ) -> ScriptDialogResult {
            let alert = NSAlert()
            alert.messageText = title.isEmpty ? prompt : title
            if !title.isEmpty, !prompt.isEmpty { alert.informativeText = prompt }
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let readField: () -> String
            if multiline {
                let (scroll, textView) = Self.makeEditBox(text: def)
                alert.accessoryView = scroll
                alert.window.initialFirstResponder = textView
                readField = { textView.string }
            } else {
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
                field.stringValue = def
                alert.accessoryView = field
                alert.window.initialFirstResponder = field
                readField = { field.stringValue }
            }
            return alert.runModal() == .alertFirstButtonReturn ? .text(readField()) : .text(nil)
        }

        /// A scrollable multi-line editor for the `editbox` dialog. Configures the
        /// `NSTextView` as a proper resizable document view of the `NSScrollView`
        /// (vertically resizable, infinite `maxSize`, width-tracking text
        /// container) — without this the document view stays a fixed height, so
        /// long text doesn't lay out for scrolling and the field scrolls jerkily.
        static func makeEditBox(
            text: String,
            size: NSSize = NSSize(width: 480, height: 260)
        ) -> (NSScrollView, NSTextView) {
            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .bezelBorder
            let content = scroll.contentSize

            let textView = NSTextView(frame: NSRect(origin: .zero, size: content))
            textView.string = text
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
            )
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.containerSize = NSSize(
                width: content.width, height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = true

            scroll.documentView = textView
            return (scroll, textView)
        }

        private static func choose(
            _ prompt: String,
            _ title: String,
            _ items: [String]
        ) -> ScriptDialogResult {
            guard !items.isEmpty else { return .index(nil) }
            let alert = NSAlert()
            alert.messageText = title.isEmpty ? prompt : title
            if !title.isEmpty, !prompt.isEmpty { alert.informativeText = prompt }
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
            popup.addItems(withTitles: items)
            alert.accessoryView = popup
            return alert
                .runModal() == .alertFirstButtonReturn ? .index(popup.indexOfSelectedItem + 1) : .index(nil)
        }

        private static func openFile(_ message: String, _ directory: Bool) -> ScriptDialogResult {
            let panel = NSOpenPanel()
            panel.canChooseFiles = !directory
            panel.canChooseDirectories = directory
            panel.allowsMultipleSelection = false
            panel.message = message
            return panel.runModal() == .OK ? .path(panel.url?.path) : .path(nil)
        }
    }
#endif
