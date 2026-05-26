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
    public final class MudTextView: NSTextView {
        /// Cached encoders; cheap to instantiate but no reason to recreate
        /// per copy invocation.
        private let ansiEncoder = SGREncoder()
        private let aardwolfEncoder = AardwolfCodeEncoder()
        private let htmlEncoder = HTMLEncoder()

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
#endif
