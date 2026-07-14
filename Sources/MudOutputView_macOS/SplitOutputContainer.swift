#if os(macOS)
    import AppKit

    /// Hosts the scrollback output with a Mudlet-style **live-tail split**.
    ///
    /// While you're scrolled to the bottom it's a single, normal scroll view.
    /// The moment you scroll *up* to read history, a small pane pinned to the
    /// bottom edge appears and keeps showing the latest lines — so you can read
    /// back and watch new output (and keep typing against the live prompt) at
    /// the same time. Scrolling back to the bottom hides the pane again.
    ///
    /// The bottom pane is an overlay on the main scroll view (rather than a true
    /// splitter that reflows the history), so toggling it never disturbs the
    /// reader's scroll position. ``RenderCoordinator`` keeps the pane's text
    /// current; this view only decides when it's visible.
    ///
    /// This mirrors Mudlet's `TConsole` upper/lower-pane design (the reference
    /// that actually does a live tail; MUSHclient merely *freezes* output on
    /// scroll-up). Improvement over Mudlet: no manual "cancel split" — it tracks
    /// the scroll position automatically.
    final class SplitOutputContainer: NSView {
        let scrollView: NSScrollView
        let tailScrollView: NSScrollView
        private let separator = TailDividerView()
        /// Translucent "jump to latest" affordance, shown with the tail; clicking
        /// it scrolls the history back to the bottom (which dismisses the split).
        private let jumpButton = NSButton()
        /// Invisible grab strip over the divider — drag it to resize the tail
        /// pane (read more combat history as a static window). Owns its own
        /// resize cursor + drag tracking.
        private let resizeHandle = TailResizeHandle()
        /// The tail pane's height (the constant we mutate while dragging the
        /// divider). Decoupled from the line count so the user can read back
        /// further; ``RenderCoordinator`` retains enough lines to fill it.
        private var tailHeightConstraint: NSLayoutConstraint!

        /// One line's height, for clamping the drag to a sensible min/max.
        private let lineHeight: CGFloat
        /// Persisted dragged height, so the pane stays the size the user chose.
        private static let heightDefaultsKey = "output.tailHeight"

        /// Reveal the tail once scrolled more than this many points above the
        /// bottom (a couple of points of slop so a pin-to-bottom doesn't flicker
        /// the pane on/off).
        private let splitThreshold: CGFloat = 8

        init(
            scrollView: NSScrollView,
            tailScrollView: NSScrollView,
            tailHeight: CGFloat,
            lineHeight: CGFloat
        ) {
            self.scrollView = scrollView
            self.tailScrollView = tailScrollView
            self.lineHeight = max(1, lineHeight)
            super.init(frame: .zero)

            configureJumpButton()
            tailScrollView.isHidden = true
            separator.isHidden = true
            jumpButton.isHidden = true
            resizeHandle.isHidden = true
            resizeHandle.onDrag = { [weak self] event in self?.handleResizeDrag(event) }
            resizeHandle.onActiveChanged = { [weak separator] active in
                separator?.isActive = active
            }

            // Restore the user's chosen height (falls back to the default).
            let saved = UserDefaults.standard.double(forKey: Self.heightDefaultsKey)
            let initialHeight = saved > 0 ? CGFloat(saved) : tailHeight
            tailHeightConstraint = tailScrollView.heightAnchor.constraint(equalToConstant: initialHeight)

            for sub in [scrollView, tailScrollView, separator, jumpButton, resizeHandle] {
                sub.translatesAutoresizingMaskIntoConstraints = false
                addSubview(sub)
            }
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

                tailScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                tailScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                tailScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                tailHeightConstraint,

                separator.leadingAnchor.constraint(equalTo: leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                separator.bottomAnchor.constraint(equalTo: tailScrollView.topAnchor),
                separator.heightAnchor.constraint(equalToConstant: 10),

                // A wider invisible grab strip centred on the visible divider.
                resizeHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
                resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
                resizeHandle.centerYAnchor.constraint(equalTo: separator.centerYAnchor),
                resizeHandle.heightAnchor.constraint(equalToConstant: 12),

                // Bottom-right of the (non-scrolling) live-tail pane.
                jumpButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                jumpButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                jumpButton.widthAnchor.constraint(equalToConstant: 28),
                jumpButton.heightAnchor.constraint(equalToConstant: 28)
            ])

            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollPositionChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// A borderless, translucent down-arrow disc — elegant at rest, and
        /// obvious in intent (jump to the newest output). It brightens on hover.
        private func configureJumpButton() {
            jumpButton.isBordered = false
            jumpButton.bezelStyle = .regularSquare
            jumpButton.imagePosition = .imageOnly
            jumpButton.refusesFirstResponder = true
            jumpButton.image = NSImage(
                systemSymbolName: "arrow.down.circle.fill",
                accessibilityDescription: "Scroll to latest"
            )?.withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
            jumpButton.contentTintColor = .white
            jumpButton.alphaValue = 0.3
            jumpButton.toolTip = "Jump to the latest output"
            jumpButton.target = self
            jumpButton.action = #selector(jumpToBottom)
        }

        @objc private func jumpToBottom() {
            if let outputScrollView = scrollView as? BottomPinnedOutputScrollView {
                outputScrollView.followTailAndScrollToBottom(reason: "jump-button")
            } else {
                (scrollView.documentView as? NSTextView)?.scrollToEndOfDocument(nil)
            }
            updateTailVisibility()
        }

        @objc private func scrollPositionChanged() {
            updateTailVisibility()
        }

        /// Brighten the jump button while hovered (still translucent, but clearly
        /// interactive). Tracking the whole view is fine — it's a tiny disc.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            guard !jumpButton.isHidden else { return }
            let point = convert(event.locationInWindow, from: nil)
            let hovering = jumpButton.frame.insetBy(dx: -6, dy: -6).contains(point)
            jumpButton.animator().alphaValue = hovering ? 0.8 : 0.3
        }

        override func layout() {
            super.layout()
            updateTailVisibility()
        }

        private func updateTailVisibility() {
            let docHeight = scrollView.documentView?.frame.height ?? 0
            let visible = scrollView.contentView.documentVisibleRect
            let show = Self.shouldShowTail(
                documentHeight: docHeight,
                visibleOriginY: visible.origin.y,
                visibleHeight: visible.height,
                threshold: splitThreshold
            )
            guard show == tailScrollView.isHidden else { return } // state changed
            tailScrollView.isHidden = !show
            separator.isHidden = !show
            jumpButton.isHidden = !show
            resizeHandle.isHidden = !show
            jumpButton.alphaValue = 0.3 // reset hover brightness when re-shown
            if show {
                scrollTailToBottom()
            }
        }

        /// Resize the tail pane as the divider is dragged. The pane is pinned to
        /// the bottom edge, so its height is the pointer's distance from the
        /// bottom, clamped to [3 lines, 70% of the view] and persisted so the
        /// chosen size survives relaunch. ``RenderCoordinator`` retains enough
        /// recent lines to fill a taller pane.
        private func handleResizeDrag(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let minHeight = lineHeight * 3 + 16
            let maxHeight = max(minHeight, bounds.height * 0.7)
            let proposed = min(max(point.y, minHeight), maxHeight)
            tailHeightConstraint.constant = proposed
            UserDefaults.standard.set(Double(proposed), forKey: Self.heightDefaultsKey)
            scrollTailToBottom()
        }

        private func scrollTailToBottom() {
            if let tailScrollView = tailScrollView as? PassthroughScrollView {
                tailScrollView.scrollToDocumentBottom()
            } else {
                (tailScrollView.documentView as? NSTextView)?.scrollToEndOfDocument(nil)
            }
        }

        /// Pure decision: show the live tail only when the content is taller
        /// than the viewport *and* the viewport is scrolled up past `threshold`.
        /// (Text views are flipped, so the bottom is `origin.y + height`.)
        nonisolated static func shouldShowTail(
            documentHeight: CGFloat,
            visibleOriginY: CGFloat,
            visibleHeight: CGFloat,
            threshold: CGFloat
        ) -> Bool {
            guard documentHeight > visibleHeight else { return false }
            let distanceFromBottom = documentHeight - (visibleOriginY + visibleHeight)
            return distanceFromBottom > threshold
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    /// Visible split marker for the live-tail pane. A plain `NSBox.separator`
    /// was effectively invisible on the black MUD output; this draws a subtle
    /// full-width rule plus a centered grab pill, brightening when interactive.
    final class TailDividerView: NSView {
        var isActive = false {
            didSet { needsDisplay = true }
        }

        override var isFlipped: Bool {
            true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            let background = NSColor.black.withAlphaComponent(isActive ? 0.42 : 0.28)
            background.setFill()
            bounds.fill()

            let ruleColor = isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.85)
                : NSColor.white.withAlphaComponent(0.32)
            ruleColor.setFill()
            NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()

            let gripWidth = min(CGFloat(64), max(CGFloat(36), bounds.width * 0.08))
            let grip = NSRect(
                x: (bounds.width - gripWidth) / 2,
                y: 3,
                width: gripWidth,
                height: 4
            )
            let gripColor = isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.95)
                : NSColor.white.withAlphaComponent(0.45)
            gripColor.setFill()
            NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
        }
    }

    /// A thin, invisible strip over the live-tail divider: shows a vertical
    /// resize cursor and forwards drags to ``SplitOutputContainer`` (which
    /// adjusts the pane height). The visible divider underneath owns the chrome.
    final class TailResizeHandle: NSView {
        var onDrag: ((NSEvent) -> Void)?
        var onActiveChanged: ((Bool) -> Void)?

        private var trackingArea: NSTrackingArea?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            )
            self.trackingArea = trackingArea
            addTrackingArea(trackingArea)
        }

        override func mouseEntered(with _: NSEvent) {
            onActiveChanged?(true)
        }

        override func mouseExited(with _: NSEvent) {
            onActiveChanged?(false)
        }

        override func mouseDown(with _: NSEvent) {
            // Accept the mouse-down so the subsequent drag tracks to this view.
            onActiveChanged?(true)
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag?(event)
        }

        override func mouseUp(with _: NSEvent) {
            onActiveChanged?(false)
        }
    }

    /// A scroll view that forwards its scroll-wheel events to another scroll
    /// view. Used for the live-tail pane: the tail itself has nothing to scroll,
    /// so without this, scrolling while the cursor is over the overlay would be
    /// swallowed there and the history would stay stuck scrolled-up (you could
    /// never scroll back down to dismiss the split). Forwarding sends those
    /// gestures to the history view instead.
    final class PassthroughScrollView: NSScrollView {
        weak var forwardingTarget: NSScrollView?

        func scrollToDocumentBottom() {
            (documentView as? NSTextView)?.scrollToEndOfDocument(nil)
            for _ in 0..<2 {
                settleDocumentGeometry()
                alignToDocumentBottom()
            }
        }

        private func alignToDocumentBottom() {
            guard let documentView else { return }
            let visible = contentView.documentVisibleRect
            let targetY = max(documentView.frame.minY, documentView.frame.maxY - visible.height)
            contentView.scroll(to: CGPoint(x: visible.minX, y: targetY))
            reflectScrolledClipView(contentView)
        }

        private func settleDocumentGeometry() {
            window?.contentView?.layoutSubtreeIfNeeded()
            guard let textView = documentView as? NSTextView else { return }
            if let layoutManager = textView.textLayoutManager {
                if let documentRange = layoutManager.textContentManager?.documentRange {
                    layoutManager.ensureLayout(for: documentRange)
                }
            }
            textView.layoutSubtreeIfNeeded()
            window?.contentView?.layoutSubtreeIfNeeded()
        }

        override func scrollWheel(with event: NSEvent) {
            if let forwardingTarget {
                forwardingTarget.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }

    /// Main output scroll view that preserves bottom pinning across viewport
    /// resizes, e.g. when the command input grows or shrinks underneath it.
    final class BottomPinnedOutputScrollView: NSScrollView {
        enum ScrollMode: String {
            case followingTail = "follow"
            case reviewing = "review"
        }

        var autoScrollThreshold: CGFloat = 32
        private(set) var scrollMode: ScrollMode = .followingTail
        private(set) var scrollModeReason = "initial"
        private(set) var userInteractionGeneration = 0
        private var programmaticScrollDepth = 0
        private var reviewOriginGeneration = 0
        var onWheelDiagnostic: ((String) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userDidLiveScroll),
                name: NSScrollView.didLiveScrollNotification,
                object: self
            )
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func setFrameSize(_ newSize: NSSize) {
            let wasFollowingTail = scrollMode == .followingTail
            super.setFrameSize(newSize)
            if wasFollowingTail {
                scrollToBottomSoon()
            }
        }

        override func scrollWheel(with event: NSEvent) {
            let previousMode = scrollMode
            let diagnostic = onWheelDiagnostic.map { _ in
                WheelEventDiagnostic(
                    event: event,
                    beforeOriginY: contentView.bounds.origin.y
                )
            }

            let coarseRows = CoarseWheelNavigation.rowDelta(for: event)
            if let coarseRows, scrollByVisualRows(coarseRows) {
                emitWheelTransitionDiagnostic(diagnostic, from: previousMode)
                return
            }

            let reviewsHistory = event.scrollingDeltaY > 0
            if reviewsHistory {
                beginReviewing(reason: "wheel")
            } else {
                userInteractionGeneration += 1
            }
            super.scrollWheel(with: event)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if reviewsHistory {
                    preserveReviewOrigin(contentView.bounds.origin)
                } else {
                    noteUserScroll(reason: "wheel")
                }
                emitWheelTransitionDiagnostic(diagnostic, from: previousMode)
            }
        }

        func setInitialScrollMode(_ mode: ScrollMode) {
            setScrollMode(mode, reason: mode == .followingTail ? "initial-bottom" : "initial-top")
        }

        func followTailAndScrollToBottom(reason: String) {
            userInteractionGeneration += 1
            setScrollMode(.followingTail, reason: reason)
            scrollToBottomSoon()
        }

        func beginReviewing(reason: String) {
            userInteractionGeneration += 1
            setScrollMode(.reviewing, reason: reason)
        }

        /// A selection is review intent only when AppKit moved the viewport
        /// away from the live tail, such as for Find or drag-autoscroll.
        func noteSelectionChange() {
            guard programmaticScrollDepth == 0,
                  scrollMode == .followingTail,
                  !isScrolledToBottom()
            else { return }
            beginReviewing(reason: "selection")
        }

        @discardableResult
        func scrollByVisualPage(_ direction: TextViewportProbe.VisualPageDirection) -> Bool {
            guard let textView = documentView as? NSTextView,
                  let targetY = TextViewportProbe.visualPageOrigin(
                      in: textView,
                      direction: direction
                  )
            else { return false }

            userInteractionGeneration += 1
            invalidateReviewOriginPreservation()
            performProgrammaticScroll {
                let current = contentView.documentVisibleRect.origin
                alignToDocumentOrigin(CGPoint(x: current.x, y: targetY))
                TextViewportProbe.layoutViewport(in: textView)
            }

            let mode: ScrollMode = isAtUserTail() ? .followingTail : .reviewing
            setScrollMode(mode, reason: "page-key")
            if mode == .reviewing {
                preserveReviewOrigin(contentView.bounds.origin)
            }
            return true
        }

        func scrollToBottomPreservingMode() {
            performProgrammaticScroll {
                (documentView as? NSTextView)?.scrollToEndOfDocument(nil)
                alignToDocumentBottom()
            }
        }

        func noteUserScroll(reason: String) {
            guard programmaticScrollDepth == 0 else { return }
            userInteractionGeneration += 1
            let mode: ScrollMode = isAtUserTail() ? .followingTail : .reviewing
            setScrollMode(mode, reason: reason)
            if mode == .reviewing {
                preserveReviewOrigin(contentView.bounds.origin)
            }
        }

        func preserveReviewOrigin(_ origin: CGPoint) {
            reviewOriginGeneration += 1
            let originGeneration = reviewOriginGeneration
            let expectedInteraction = userInteractionGeneration
            alignToDocumentOrigin(origin)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                guard let self,
                      scrollMode == .reviewing,
                      reviewOriginGeneration == originGeneration,
                      userInteractionGeneration == expectedInteraction
                else { return }
                alignToDocumentOrigin(origin)
            }
        }

        func invalidateReviewOriginPreservation() {
            reviewOriginGeneration += 1
        }

        private func scrollToBottomSoon() {
            scrollToBottomPreservingMode()
            DispatchQueue.main.async { [weak self] in
                self?.scrollToBottomPreservingMode()
            }
        }

        private func alignToDocumentBottom() {
            guard let documentView else { return }
            let visible = contentView.documentVisibleRect
            let targetY = max(documentView.frame.minY, documentView.frame.maxY - visible.height)
            alignToDocumentOrigin(CGPoint(x: visible.minX, y: targetY))
        }

        private func alignToDocumentOrigin(_ origin: CGPoint) {
            guard let documentView else { return }
            let maximumY = max(
                documentView.frame.minY,
                documentView.frame.maxY - contentView.documentVisibleRect.height
            )
            contentView.scroll(to: CGPoint(
                x: origin.x,
                y: min(max(documentView.frame.minY, origin.y), maximumY)
            ))
            reflectScrolledClipView(contentView)
        }

        private func setScrollMode(_ mode: ScrollMode, reason: String) {
            scrollMode = mode
            scrollModeReason = reason
        }

        private func performProgrammaticScroll(_ action: () -> Void) {
            programmaticScrollDepth += 1
            action()
            programmaticScrollDepth -= 1
        }

        @objc private func userDidLiveScroll() {
            noteUserScroll(reason: "live-scroll")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif
