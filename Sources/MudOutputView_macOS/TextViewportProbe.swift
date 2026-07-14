#if os(macOS)
    import AppKit
    import MudCore

    struct RenderedLineSpan {
        let id: LineID
        let utf16Length: Int
    }

    struct OutputViewportAnchor: Equatable {
        let lineID: LineID
        let utf16OffsetInLine: Int
        let viewportOffsetFromLineTop: CGFloat
    }

    struct TextViewportProbeMetrics {
        let viewportStartUTF16: Int?
        let viewportEndUTF16: Int?
        let topLayoutFragmentState: Int?
        let topVisualLineCount: Int?
        let topVisualLineClip: CGFloat?
        let bottomVisualLineClip: CGFloat?
    }

    struct TextViewportHealthContext {
        let renderedLines: Int
        let pinnedThreshold: CGFloat
        let extra: String
    }

    @MainActor
    enum TextViewportProbe {
        static func metrics(for textView: NSTextView) -> TextViewportProbeMetrics {
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager
            else {
                return TextViewportProbeMetrics(
                    viewportStartUTF16: nil,
                    viewportEndUTF16: nil,
                    topLayoutFragmentState: nil,
                    topVisualLineCount: nil,
                    topVisualLineClip: nil,
                    bottomVisualLineClip: nil
                )
            }

            let documentStart = contentManager.documentRange.location
            let viewportRange = layoutManager.textViewportLayoutController.viewportRange
            let viewportStart = viewportRange.map {
                contentManager.offset(from: documentStart, to: $0.location)
            }
            let viewportEnd = viewportRange.map {
                contentManager.offset(from: documentStart, to: $0.endLocation)
            }
            let fragment = topLayoutFragment(for: textView, layoutManager: layoutManager)
            let clipping = visualLineClipping(for: textView, layoutManager: layoutManager)
            return TextViewportProbeMetrics(
                viewportStartUTF16: viewportStart,
                viewportEndUTF16: viewportEnd,
                topLayoutFragmentState: fragment.map { Int($0.state.rawValue) },
                topVisualLineCount: fragment?.textLineFragments.count,
                topVisualLineClip: clipping?.top,
                bottomVisualLineClip: clipping?.bottom
            )
        }

        static func healthSnapshot(
            for textView: NSTextView,
            surface: String,
            reason: String,
            context: TextViewportHealthContext
        ) -> TextViewHealthSnapshot {
            let scrollView = textView.enclosingScrollView
            let visible = scrollView?.contentView.documentVisibleRect ?? textView.visibleRect
            let documentWidth = scrollView?.documentView?.frame.width ?? textView.frame.width
            let documentHeight = scrollView?.documentView?.frame.height ?? textView.frame.height
            let distanceFromBottom = documentHeight - visible.maxY
            let viewport = metrics(for: textView)
            return TextViewHealthSnapshot(
                surface: surface,
                reason: reason,
                renderedLines: context.renderedLines,
                storageUTF16Length: textView.textStorage?.length ?? 0,
                textViewBoundsHeight: Double(textView.bounds.height),
                documentHeight: Double(documentHeight),
                visibleOriginY: Double(visible.origin.y),
                visibleHeight: Double(visible.height),
                distanceFromBottom: Double(distanceFromBottom),
                isPinnedToBottom: distanceFromBottom < context.pinnedThreshold,
                isViewHidden: textView.isHiddenOrHasHiddenAncestor,
                hasWindow: textView.window != nil,
                textViewBoundsWidth: Double(textView.bounds.width),
                documentWidth: Double(documentWidth),
                visibleOriginX: Double(visible.origin.x),
                visibleWidth: Double(visible.width),
                textContainerWidth: Double(textView.textContainer?.size.width ?? 0),
                usesTextLayoutManager: textView.textLayoutManager != nil,
                viewportStartUTF16: viewport.viewportStartUTF16,
                viewportEndUTF16: viewport.viewportEndUTF16,
                topLayoutFragmentState: viewport.topLayoutFragmentState,
                topVisualLineCount: viewport.topVisualLineCount,
                topVisualLineClip: viewport.topVisualLineClip.map(Double.init),
                bottomVisualLineClip: viewport.bottomVisualLineClip.map(Double.init),
                extra: context.extra
            )
        }

        /// Cheap confirmation used by tail reconciliation. Geometry can say
        /// "at bottom" while TextKit's active viewport still ends thousands
        /// of UTF-16 units short after an invalidating prefix edit.
        static func viewportEndsAtStorageEnd(in textView: NSTextView) -> Bool? {
            let storageLength = textView.textStorage?.length ?? 0
            guard storageLength > 0 else { return true }
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager,
                  let viewportRange = layoutManager.textViewportLayoutController.viewportRange
            else { return nil }
            let documentStart = contentManager.documentRange.location
            let viewportEnd = contentManager.offset(
                from: documentStart,
                to: viewportRange.endLocation
            )
            guard viewportEnd != NSNotFound else { return nil }
            return viewportEnd >= storageLength
        }

        private static func visualLineClipping(
            for textView: NSTextView,
            layoutManager: NSTextLayoutManager
        ) -> (top: CGFloat, bottom: CGFloat)? {
            let visible = textView.enclosingScrollView?.contentView.documentVisibleRect
                ?? textView.visibleRect
            let documentBottom = textView.bounds.maxY
            guard documentBottom > 0 else { return nil }
            let topPointY = min(max(visible.minY + 0.5, 0.5), documentBottom - 0.5)
            let bottomPointY = min(max(visible.maxY - 0.5, 0.5), documentBottom - 0.5)
            guard let topLine = visualLine(at: topPointY, in: textView, layoutManager: layoutManager),
                  let bottomLine = visualLine(at: bottomPointY, in: textView, layoutManager: layoutManager)
            else { return nil }
            return (
                top: max(0, visible.minY - topLine.lowerBound),
                bottom: max(0, bottomLine.upperBound - visible.maxY)
            )
        }

        static func visualLine(
            at documentY: CGFloat,
            in textView: NSTextView,
            layoutManager: NSTextLayoutManager
        ) -> ClosedRange<CGFloat>? {
            let origin = textView.textContainerOrigin
            let containerY = max(0, documentY - origin.y)
            let point = CGPoint(x: 1, y: containerY)
            guard let fragment = layoutManager.textLayoutFragment(for: point),
                  let line = fragment.textLineFragment(
                      forVerticalOffset: containerY - fragment.layoutFragmentFrame.minY,
                      requiresExactMatch: false
                  )
            else { return nil }
            let lineTop = origin.y
                + fragment.layoutFragmentFrame.minY
                + line.typographicBounds.minY
            return lineTop...(lineTop + line.typographicBounds.height)
        }

        static func captureAnchor(
            in textView: NSTextView,
            renderedLines: [RenderedLineSpan]
        ) -> OutputViewportAnchor? {
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
            return OutputViewportAnchor(
                lineID: linePosition.line.id,
                utf16OffsetInLine: characterOffset - linePosition.startUTF16,
                viewportOffsetFromLineTop: visibleTop - lineTop
            )
        }

        static func layoutViewport(in textView: NSTextView) {
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }

        @discardableResult
        static func restoreAnchor(
            _ anchor: OutputViewportAnchor,
            in textView: NSTextView,
            renderedLines: [RenderedLineSpan]
        ) -> Bool {
            let scrollView = textView.enclosingScrollView as? BottomPinnedOutputScrollView
            scrollView?.invalidateReviewOriginPreservation()
            let firstPass = restoreAnchorNow(anchor, in: textView, renderedLines: renderedLines)
            let refinedPass = restoreAnchorNow(anchor, in: textView, renderedLines: renderedLines)
            let expectedReason = scrollView?.scrollModeReason
            let expectedInteraction = scrollView?.userInteractionGeneration
            DispatchQueue.main.async { [weak textView] in
                guard let textView,
                      let scrollView = textView.enclosingScrollView
                      as? BottomPinnedOutputScrollView,
                      scrollView.scrollMode == .reviewing,
                      scrollView.scrollModeReason == expectedReason,
                      scrollView.userInteractionGeneration == expectedInteraction
                else { return }
                _ = restoreAnchorNow(anchor, in: textView, renderedLines: renderedLines)
            }
            return firstPass || refinedPass
        }

        private static func restoreAnchorNow(
            _ anchor: OutputViewportAnchor,
            in textView: NSTextView,
            renderedLines: [RenderedLineSpan]
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
            at characterOffset: Int,
            in lines: [RenderedLineSpan]
        ) -> (line: RenderedLineSpan, startUTF16: Int)? {
            var start = 0
            for line in lines {
                let end = start + line.utf16Length
                if characterOffset < end {
                    return (line, start)
                }
                start = end
            }
            guard let last = lines.last else { return nil }
            return (last, max(0, start - last.utf16Length))
        }

        private static func renderedLine(
            with id: LineID,
            in lines: [RenderedLineSpan]
        ) -> (line: RenderedLineSpan, startUTF16: Int)? {
            var start = 0
            for line in lines {
                if line.id == id { return (line, start) }
                start += line.utf16Length
            }
            return nil
        }
    }
#endif
