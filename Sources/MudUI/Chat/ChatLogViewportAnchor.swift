#if os(macOS)
    import AppKit

    struct ChatRenderedLineSpan: Equatable {
        let id: UInt64
        var utf16Length: Int
    }

    struct ChatViewportAnchor: Equatable {
        let lineID: UInt64
        let utf16OffsetInLine: Int
        let viewportOffsetFromLineTop: CGFloat
    }

    /// Captures the top visible logical Channels line before a TextKit mutation
    /// and resolves the same immutable line id afterwards. This prevents a
    /// rolling 10k prefix trim from shifting review-mode scrollback.
    @MainActor
    enum ChatLogViewportAnchor {
        static func capture(
            in textView: NSTextView,
            renderedLines: [ChatRenderedLineSpan]
        ) -> ChatViewportAnchor? {
            guard !renderedLines.isEmpty,
                  let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager
            else { return nil }

            layoutManager.textViewportLayoutController.layoutViewport()
            guard let fragment = topLayoutFragment(for: textView, layoutManager: layoutManager)
            else { return nil }
            layoutManager.ensureLayout(for: fragment.rangeInElement)

            let visibleTop = scrollView.contentView.documentVisibleRect.minY
            let pointY = max(0, visibleTop - textView.textContainerOrigin.y + 0.5)
            guard let lineFragment = fragment.textLineFragment(
                forVerticalOffset: pointY - fragment.layoutFragmentFrame.minY,
                requiresExactMatch: false
            ) else { return nil }

            let documentStart = contentManager.documentRange.location
            let fragmentOffset = contentManager.offset(
                from: documentStart,
                to: fragment.rangeInElement.location
            )
            guard fragmentOffset != NSNotFound else { return nil }
            let characterOffset = fragmentOffset + lineFragment.characterRange.location
            guard let linePosition = renderedLine(at: characterOffset, in: renderedLines) else {
                return nil
            }
            let lineTop = textView.textContainerOrigin.y
                + fragment.layoutFragmentFrame.minY
                + lineFragment.typographicBounds.minY
            return ChatViewportAnchor(
                lineID: linePosition.line.id,
                utf16OffsetInLine: characterOffset - linePosition.startUTF16,
                viewportOffsetFromLineTop: visibleTop - lineTop
            )
        }

        @discardableResult
        static func restore(
            _ anchor: ChatViewportAnchor,
            in textView: NSTextView,
            renderedLines: [ChatRenderedLineSpan]
        ) -> Bool {
            let firstPass = restoreNow(anchor, in: textView, renderedLines: renderedLines)
            let refinedPass = restoreNow(anchor, in: textView, renderedLines: renderedLines)
            return firstPass || refinedPass
        }

        private static func restoreNow(
            _ anchor: ChatViewportAnchor,
            in textView: NSTextView,
            renderedLines: [ChatRenderedLineSpan]
        ) -> Bool {
            guard !renderedLines.isEmpty,
                  let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager
            else { return false }

            let resolved = renderedLine(with: anchor.lineID, in: renderedLines)
                ?? (line: renderedLines[0], startUTF16: 0)
            let clampedOffset = min(
                max(0, anchor.utf16OffsetInLine),
                max(0, resolved.line.utf16Length - 1)
            )
            let characterOffset = resolved.startUTF16 + clampedOffset
            let documentStart = contentManager.documentRange.location
            guard let location = contentManager.location(
                documentStart,
                offsetBy: characterOffset
            ), let range = NSTextRange(location: location, end: location)
            else { return false }

            layoutManager.ensureLayout(for: range)
            guard let fragment = layoutManager.textLayoutFragment(for: location),
                  let lineFragment = fragment.textLineFragment(
                      for: location,
                      isUpstreamAffinity: false
                  )
            else { return false }

            let lineTop = textView.textContainerOrigin.y
                + fragment.layoutFragmentFrame.minY
                + lineFragment.typographicBounds.minY
            let maximumY = max(
                0,
                (scrollView.documentView?.frame.height ?? textView.frame.height)
                    - scrollView.contentView.bounds.height
            )
            let targetY = min(max(0, lineTop + anchor.viewportOffsetFromLineTop), maximumY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            layoutManager.textViewportLayoutController.layoutViewport()
            return resolved.line.id == anchor.lineID
        }

        private static func topLayoutFragment(
            for textView: NSTextView,
            layoutManager: NSTextLayoutManager
        ) -> NSTextLayoutFragment? {
            let visible = textView.enclosingScrollView?.contentView.documentVisibleRect
                ?? textView.visibleRect
            let origin = textView.textContainerOrigin
            let point = CGPoint(
                x: max(0, visible.minX - origin.x + 1),
                y: max(0, visible.minY - origin.y + 0.5)
            )
            return layoutManager.textLayoutFragment(for: point)
                ?? layoutManager.textViewportLayoutController.viewportRange.flatMap {
                    layoutManager.textLayoutFragment(for: $0.location)
                }
        }

        private static func renderedLine(
            at utf16Offset: Int,
            in lines: [ChatRenderedLineSpan]
        ) -> (line: ChatRenderedLineSpan, startUTF16: Int)? {
            var start = 0
            for line in lines {
                if utf16Offset < start + line.utf16Length {
                    return (line, start)
                }
                start += line.utf16Length
            }
            guard let last = lines.last else { return nil }
            return (last, max(0, start - last.utf16Length))
        }

        private static func renderedLine(
            with id: UInt64,
            in lines: [ChatRenderedLineSpan]
        ) -> (line: ChatRenderedLineSpan, startUTF16: Int)? {
            var start = 0
            for line in lines {
                if line.id == id { return (line, start) }
                start += line.utf16Length
            }
            return nil
        }
    }
#endif
