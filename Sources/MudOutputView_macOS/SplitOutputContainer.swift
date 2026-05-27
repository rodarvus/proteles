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
        private let separator = NSBox()
        /// Translucent "jump to latest" affordance, shown with the tail; clicking
        /// it scrolls the history back to the bottom (which dismisses the split).
        private let jumpButton = NSButton()

        /// Reveal the tail once scrolled more than this many points above the
        /// bottom (a couple of points of slop so a pin-to-bottom doesn't flicker
        /// the pane on/off).
        private let splitThreshold: CGFloat = 8

        init(scrollView: NSScrollView, tailScrollView: NSScrollView, tailHeight: CGFloat) {
            self.scrollView = scrollView
            self.tailScrollView = tailScrollView
            super.init(frame: .zero)

            separator.boxType = .separator
            configureJumpButton()
            tailScrollView.isHidden = true
            separator.isHidden = true
            jumpButton.isHidden = true

            for sub in [scrollView, tailScrollView, separator, jumpButton] {
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
                tailScrollView.heightAnchor.constraint(equalToConstant: tailHeight),

                separator.leadingAnchor.constraint(equalTo: leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                separator.bottomAnchor.constraint(equalTo: tailScrollView.topAnchor),
                separator.heightAnchor.constraint(equalToConstant: 1),

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
            (scrollView.documentView as? NSTextView)?.scrollToEndOfDocument(nil)
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
            jumpButton.alphaValue = 0.3 // reset hover brightness when re-shown
            if show {
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

    /// A scroll view that forwards its scroll-wheel events to another scroll
    /// view. Used for the live-tail pane: the tail itself has nothing to scroll,
    /// so without this, scrolling while the cursor is over the overlay would be
    /// swallowed there and the history would stay stuck scrolled-up (you could
    /// never scroll back down to dismiss the split). Forwarding sends those
    /// gestures to the history view instead.
    final class PassthroughScrollView: NSScrollView {
        weak var forwardingTarget: NSScrollView?

        override func scrollWheel(with event: NSEvent) {
            if let forwardingTarget {
                forwardingTarget.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
#endif
