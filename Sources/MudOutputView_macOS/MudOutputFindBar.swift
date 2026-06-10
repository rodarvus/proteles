#if os(macOS)
    import AppKit

    /// Find-in-scrollback (D-104): routes the Edit ▸ Find menu commands to
    /// the *findable* output view in a window — the one history `NSTextView`
    /// built with `MudOutputView(findable: true)`. The view itself uses the
    /// system `NSTextFinder` find bar (incremental search, highlight-all,
    /// case-insensitivity, "Insert Pattern" wildcard tokens), so all this
    /// helper does is locate the view and hand it the standard action.
    ///
    /// Explicit targeting is required because the command field deliberately
    /// keeps first-responder status (DESIGN.md §3.2 "the command input always
    /// has focus"), so the find actions would never reach the output view
    /// through the responder chain.
    public enum MudOutputFindBar {
        /// Perform a find-bar action on `window`'s findable output view; a
        /// no-op when the window has none (e.g. the Scripts window).
        @MainActor
        public static func perform(_ action: NSTextFinder.Action, in window: NSWindow?) {
            guard let window, let target = findableTextView(in: window.contentView)
            else { return }
            if action == .showFindInterface {
                window.makeFirstResponder(target)
            }
            // performTextFinderAction(_:) reads the action from the sender's
            // tag (the AppKit menu-item convention).
            let sender = NSMenuItem()
            sender.tag = action.rawValue
            target.performTextFinderAction(sender)
        }

        /// Depth-first search for the (single) find-bar-enabled text view.
        @MainActor
        static func findableTextView(in view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if let textView = view as? NSTextView, textView.usesFindBar {
                return textView
            }
            for subview in view.subviews {
                if let found = findableTextView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }
#endif
