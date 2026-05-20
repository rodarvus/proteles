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
        /// Cached encoder; cheap to instantiate but no reason to recreate
        /// per copy invocation.
        private let encoder = SGREncoder()

        @objc public func copyWithCodes(_: Any?) {
            guard let storage = textStorage else { return }
            let selection = selectedRange()
            guard selection.length > 0 else { return }

            let selectedAttributed = storage.attributedSubstring(from: selection)
            let encoded = encoder.encode(selectedAttributed)

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(encoded, forType: .string)
        }

        override public func validateUserInterfaceItem(
            _ item: any NSValidatedUserInterfaceItem
        ) -> Bool {
            if item.action == #selector(copyWithCodes(_:)) {
                return selectedRange().length > 0
            }
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

            let item = NSMenuItem(
                title: "Copy with Colour Codes",
                action: #selector(copyWithCodes(_:)),
                keyEquivalent: "C"
            )
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            menu.insertItem(item, at: insertIndex)

            return menu
        }
    }
#endif
