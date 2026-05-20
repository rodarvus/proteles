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
    }
#endif
