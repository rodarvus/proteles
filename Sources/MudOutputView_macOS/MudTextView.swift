#if os(macOS)
    import AppKit
    import MudCore

    /// `NSTextView` subclass that adds **Copy with Colour Codes** via a
    /// custom `copyWithCodes(_:)` action.
    ///
    /// Wires into the standard AppKit responder chain: the menu item's
    /// target is `nil`, and `NSApp.sendAction(_:to:from:)` walks the chain
    /// to find a responder that implements the action. Whichever
    /// `MudTextView` is first responder gets the call.
    ///
    /// Plain ⌘C continues to use `NSTextView`'s built-in `copy(_:)` —
    /// which already does the right thing (plain selected text on the
    /// pasteboard).
    public final class MudTextView: NSTextView, NSTextViewDelegate {
        /// Cached encoders; cheap to instantiate but no reason to recreate
        /// per copy invocation.
        private let ansiEncoder = SGREncoder()
        private let aardwolfEncoder = AardwolfCodeEncoder()
        private let htmlEncoder = HTMLEncoder()

        /// Invoked when a `proteles-cmd:` hyperlink is clicked, with the
        /// decoded command — the host sends it to the MUD. URL links
        /// (`http`/`mailto`) open in the browser instead.
        public var onCommand: ((String) -> Void)?

        /// Route hyperlink clicks: `proteles-cmd:` → send the command;
        /// otherwise open the URL in the default browser.
        public func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
            let string = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            let scheme = "proteles-cmd:"
            if string.hasPrefix(scheme) {
                let raw = String(string.dropFirst(scheme.count)).drop { $0 == "/" }
                onCommand?(raw.removingPercentEncoding ?? String(raw))
                return true
            }
            if let url = link as? URL { NSWorkspace.shared.open(url) }
            return true
        }

        /// The command input field is the window's permanent typing target.
        /// When the user types a printable key while the *output* has focus
        /// (e.g. right after selecting text to copy), focus snaps back to the
        /// command field and the keystroke is re-delivered there — so the input
        /// is "always ready" (UI revamp requirement). ⌘-shortcuts (copy,
        /// select-all, find) and arrow/selection keys stay with the text view.
        override public func keyDown(with event: NSEvent) {
            let isPlainTyping = event.modifierFlags
                .isDisjoint(with: [.command, .control, .option, .function])
            guard isPlainTyping,
                  !Self.navigationKeyCodes.contains(event.keyCode),
                  let field = commandField,
                  window?.firstResponder !== field
            else {
                super.keyDown(with: event)
                return
            }
            window?.makeFirstResponder(field)
            NSApp.postEvent(event, atStart: true) // re-deliver to the now-focused field
        }

        /// Arrow/page/home/end/tab — leave these for scrolling/selection.
        private static let navigationKeyCodes: Set<UInt16> = [123, 124, 125, 126, 116, 121, 115, 119, 48]

        /// The window's command input field, located by its stable identifier.
        private var commandField: NSView? {
            window?.contentView?.firstDescendant(matching: "proteles.command")
        }

        /// Copy the selection as ANSI SGR escapes (terminals, Discord, other
        /// clients).
        @objc public func copyWithCodes(_: Any?) {
            copySelection { ansiEncoder.encode($0) }
        }

        /// Copy the selection as Aardwolf `@`-colour codes (pastes back into
        /// Aardwolf notes/forum/channels or to another Aardwolf player) —
        /// the native `aard_Copy_Colour_Codes`.
        @objc public func copyAsAardwolfCodes(_: Any?) {
            copySelection { aardwolfEncoder.encode($0) }
        }

        /// Copy the selection as HTML markup (`<span style="color:…">` runs in
        /// a `<pre>`) — paste the source into a forum/blog/editor.
        @objc public func copyAsHTML(_: Any?) {
            copySelection { htmlEncoder.encode($0) }
        }

        /// Encode the current selection via `encode` and place it on the
        /// pasteboard. No-op when nothing is selected.
        private func copySelection(_ encode: (NSAttributedString) -> String) {
            guard let storage = textStorage else { return }
            let selection = selectedRange()
            guard selection.length > 0 else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(encode(storage.attributedSubstring(from: selection)), forType: .string)
        }

        override public func validateUserInterfaceItem(
            _ item: any NSValidatedUserInterfaceItem
        ) -> Bool {
            let action = item.action
            let isCopyCodes = action == #selector(copyWithCodes(_:))
                || action == #selector(copyAsAardwolfCodes(_:))
                || action == #selector(copyAsHTML(_:))
            if isCopyCodes { return selectedRange().length > 0 }
            return super.validateUserInterfaceItem(item)
        }

        /// Inject the Copy-with-Colour-Codes item into the right-click
        /// context menu, right after the standard Copy item. The menu
        /// bar entry already exists (see `ProtelesApp.body.commands`);
        /// this is the parity affordance so users who reach for the
        /// right-click menu instead of the keyboard shortcut still get
        /// to the feature.
        override public func menu(for event: NSEvent) -> NSMenu? {
            guard let menu = super.menu(for: event) else { return nil }

            // Find the standard Copy item; fall back to inserting at
            // the start of the menu if AppKit's default lineup ever
            // changes shape.
            let insertIndex: Int = {
                if let copyIndex = menu.items.firstIndex(where: {
                    $0.action == #selector(copy(_:))
                }) {
                    return copyIndex + 1
                }
                return 0
            }()

            let ansiItem = NSMenuItem(
                title: "Copy as ANSI Colour Codes",
                action: #selector(copyWithCodes(_:)),
                keyEquivalent: "C"
            )
            ansiItem.keyEquivalentModifierMask = [.command, .shift]
            ansiItem.target = self
            menu.insertItem(ansiItem, at: insertIndex)

            let aardItem = NSMenuItem(
                title: "Copy as Aardwolf Colour Codes",
                action: #selector(copyAsAardwolfCodes(_:)),
                keyEquivalent: "c"
            )
            aardItem.keyEquivalentModifierMask = [.command, .option]
            aardItem.target = self
            menu.insertItem(aardItem, at: insertIndex + 1)

            let htmlItem = NSMenuItem(
                title: "Copy as HTML",
                action: #selector(copyAsHTML(_:)),
                keyEquivalent: "h"
            )
            htmlItem.keyEquivalentModifierMask = [.command, .option]
            htmlItem.target = self
            menu.insertItem(htmlItem, at: insertIndex + 2)

            return menu
        }
    }

    private extension NSView {
        /// Depth-first search for the descendant view with the given accessibility
        /// identifier (used to find the command input from the output view).
        func firstDescendant(matching identifier: String) -> NSView? {
            for subview in subviews {
                if subview.identifier?.rawValue == identifier {
                    return subview
                }
                if let found = subview.firstDescendant(matching: identifier) {
                    return found
                }
            }
            return nil
        }
    }
#endif
