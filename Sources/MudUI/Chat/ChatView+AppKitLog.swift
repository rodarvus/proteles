#if os(macOS)
    import AppKit
    import CoreText
    import MudCore
    import SwiftUI

    /// AppKit/TextKit chat log used on macOS so Channels selection and scrolling
    /// follow the same model as the main output instead of SwiftUI row selection.
    struct ChatLogView: NSViewRepresentable {
        let lines: [ChatLine]
        let palette: ColorPalette
        let showTimestamps: Bool
        let timestampSeconds: Bool
        let filterKey: String
        let fillOpacity: Double
        let onHealthSnapshot: ((TextViewHealthSnapshot) -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeNSView(context: Context) -> ChatLogScrollView {
            let scrollView = ChatLogScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = fillOpacity > 0
            scrollView.backgroundColor = backgroundColor
            scrollView.identifier = NSUserInterfaceItemIdentifier("proteles.channels-output")
            scrollView.setAccessibilityIdentifier("channels-output-scroll")

            let textView = ChatLogTextView()
            textView.delegate = context.coordinator
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainerInset = NSSize(width: 10, height: 6)
            textView.configure(font: Self.baseFont, background: backgroundColor)
            textView.setAccessibilityIdentifier("channels-output")
            textView.setAccessibilityLabel("Channels output")
            scrollView.documentView = textView
            context.coordinator.textView = textView
            updateNSView(scrollView, context: context)
            return scrollView
        }

        func updateNSView(_ scrollView: ChatLogScrollView, context: Context) {
            scrollView.drawsBackground = fillOpacity > 0
            scrollView.backgroundColor = backgroundColor
            guard let textView = scrollView.documentView as? ChatLogTextView else { return }
            textView.updateBackground(backgroundColor)

            renderUpdate(
                in: scrollView,
                target: ChatRenderTarget(textView: textView, coordinator: context.coordinator)
            )
        }

        private func renderUpdate(in scrollView: ChatLogScrollView, target: ChatRenderTarget) {
            let presentation = ChatRenderPresentation(
                filterKey: filterKey,
                showTimestamps: showTimestamps,
                timestampSeconds: timestampSeconds,
                palette: palette
            )
            let nextState = ChatRenderUpdatePlanner.state(
                lines: lines,
                presentation: presentation
            )
            let planned = ChatRenderUpdatePlanner.plan(
                from: target.coordinator.renderState,
                to: nextState
            )
            guard planned != .noChange else {
                target.coordinator.skippedUpdates += 1
                return
            }

            let forceBottom = !target.coordinator.hasRendered
                || target.coordinator.lastFilterKey != filterKey
            let wasPinned = scrollView.isScrolledToBottom()
            let viewport = ChatViewportState(
                forceBottom: forceBottom,
                wasPinned: wasPinned,
                previousOrigin: scrollView.contentView.bounds.origin,
                anchor: wasPinned ? nil : ChatLogViewportAnchor.capture(
                    in: target.textView,
                    renderedLines: target.coordinator.renderedLines
                )
            )
            let builder = ChatAttributedStringBuilder(
                palette: palette,
                font: Self.baseFont,
                timestampColor: NSColor.secondaryLabelColor
            )
            let operation = apply(
                planned,
                lines: lines,
                builder: builder,
                target: target
            )
            completeRenderUpdate(
                in: scrollView,
                target: target,
                viewport: viewport,
                operation: operation,
                nextState: nextState
            )
        }

        private func completeRenderUpdate(
            in scrollView: ChatLogScrollView,
            target: ChatRenderTarget,
            viewport: ChatViewportState,
            operation: String,
            nextState: ChatRenderState
        ) {
            target.coordinator.renderState = nextState
            target.coordinator.hasRendered = true
            target.coordinator.lastFilterKey = filterKey
            let storageLength = target.textView.textStorage?.length ?? 0
            assert(
                storageLength
                    == target.coordinator.renderedLines.reduce(0) { $0 + $1.utf16Length }
            )
            let transition = onHealthSnapshot.flatMap { _ in
                target.coordinator.diagnosticTransition(
                    lineCount: lines.count,
                    storageUTF16Length: storageLength,
                    filterKey: filterKey
                )
            }

            restoreScrollPosition(
                in: scrollView,
                target: target,
                viewport: viewport
            )
            let skipped = target.coordinator.skippedUpdates
            target.coordinator.skippedUpdates = 0
            let detail = skipped > 0 ? "-after-\(skipped)-noops" : ""
            let updateReason = transition.map { "transition-\($0)-\(operation)\(detail)-update" }
                ?? "\(operation)\(detail)-update"
            emitHealth(from: scrollView, reason: updateReason)
            DispatchQueue.main.async {
                let settledReason = transition.map { "transition-\($0)-\(operation)-settled" }
                    ?? "\(operation)-settled"
                emitHealth(from: scrollView, reason: settledReason)
            }
        }

        private func apply(
            _ planned: ChatRenderUpdate,
            lines: [ChatLine],
            builder: ChatAttributedStringBuilder,
            target: ChatRenderTarget
        ) -> String {
            guard case .incremental(let removeFirst, let appendFrom) = planned,
                  target.coordinator.canApplyIncremental(to: target.textView)
            else {
                rebuild(lines, builder: builder, target: target)
                return "rebuild"
            }
            applyIncremental(
                lines,
                removeFirst: removeFirst,
                appendFrom: appendFrom,
                builder: builder,
                target: target
            )
            if removeFirst > 0 {
                return appendFrom < lines.count ? "trim-append" : "trim"
            }
            return "append"
        }

        private func rebuild(
            _ lines: [ChatLine],
            builder: ChatAttributedStringBuilder,
            target: ChatRenderTarget
        ) {
            let document = PerformanceProbe.shared.measure(
                "channels.build",
                events: lines.count,
                thresholdMS: 50
            ) {
                builder.buildDocument(
                    lines,
                    showTimestamps: showTimestamps,
                    timestampSeconds: timestampSeconds
                )
            }
            PerformanceProbe.shared.measure(
                "channels.set-text",
                events: lines.count,
                thresholdMS: 50
            ) {
                guard let storage = target.textView.textStorage else { return }
                ChatTextStorageUpdater.rebuild(
                    storage: storage,
                    document: document,
                    renderedLines: &target.coordinator.renderedLines
                )
            }
        }

        private func applyIncremental(
            _ lines: [ChatLine],
            removeFirst: Int,
            appendFrom: Int,
            builder: ChatAttributedStringBuilder,
            target: ChatRenderTarget
        ) {
            let appended = PerformanceProbe.shared.measure(
                "channels.build-append",
                events: lines.count - appendFrom,
                thresholdMS: 50
            ) {
                builder.buildDocument(
                    Array(lines[appendFrom...]),
                    showTimestamps: showTimestamps,
                    timestampSeconds: timestampSeconds
                )
            }
            PerformanceProbe.shared.measure(
                removeFirst > 0 ? "channels.trim-append" : "channels.append",
                events: removeFirst + appended.renderedLines.count,
                thresholdMS: 50
            ) {
                guard let storage = target.textView.textStorage else { return }
                ChatTextStorageUpdater.applyIncremental(
                    storage: storage,
                    removeFirst: removeFirst,
                    appended: appended,
                    renderedLines: &target.coordinator.renderedLines
                )
            }
        }

        private static var baseFont: NSFont {
            .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        }

        private var backgroundColor: NSColor {
            NSColor(rgb: palette.defaultBackground)
                .withAlphaComponent(CGFloat(fillOpacity))
        }

        private func restoreScrollPosition(
            in scrollView: ChatLogScrollView,
            target: ChatRenderTarget,
            viewport: ChatViewportState
        ) {
            let shouldPin = viewport.forceBottom || viewport.wasPinned
            let phase = shouldPin ? "channels.scroll-bottom" : "channels.restore-origin"
            PerformanceProbe.shared.measure(phase, events: lines.count, thresholdMS: 50) {
                if shouldPin {
                    scrollView.scrollToBottomSoon()
                } else if restoreAnchor(target: target, viewport: viewport) {
                    // The same logical line remains at the same viewport offset.
                } else {
                    scrollView.restoreVisibleOrigin(viewport.previousOrigin)
                }
            }
        }

        private func restoreAnchor(
            target: ChatRenderTarget,
            viewport: ChatViewportState
        ) -> Bool {
            guard let anchor = viewport.anchor else { return false }
            return ChatLogViewportAnchor.restore(
                anchor,
                in: target.textView,
                renderedLines: target.coordinator.renderedLines
            )
        }

        private func emitHealth(from scrollView: ChatLogScrollView, reason: String) {
            guard let onHealthSnapshot else { return }
            let storageLength = (scrollView.documentView as? NSTextView)?.textStorage?.length ?? 0
            let snapshot = scrollView.healthSnapshot(
                reason: reason,
                renderedLines: lines.count,
                storageUTF16Length: storageLength
            )
            onHealthSnapshot(snapshot)
        }

        private struct ChatRenderTarget {
            let textView: ChatLogTextView
            let coordinator: Coordinator
        }

        private struct ChatViewportState {
            let forceBottom: Bool
            let wasPinned: Bool
            let previousOrigin: CGPoint
            let anchor: ChatViewportAnchor?
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            weak var textView: ChatLogTextView?
            var hasRendered = false
            var lastFilterKey = ""
            var renderState: ChatRenderState?
            var renderedLines: [ChatRenderedLineSpan] = []
            var skippedUpdates = 0
            private var lastDiagnosticLineCount = -1
            private var lastDiagnosticStorageLength = -1
            private var lastDiagnosticFilterKey = ""
            private var diagnosticTransitionSequence = 0

            func canApplyIncremental(to textView: ChatLogTextView) -> Bool {
                guard let renderState, let storage = textView.textStorage else { return false }
                return renderState.lineIDs == renderedLines.map(\.id)
                    && storage.length == renderedLines.reduce(0) { $0 + $1.utf16Length }
            }

            func diagnosticTransition(
                lineCount: Int,
                storageUTF16Length: Int,
                filterKey: String
            ) -> Int? {
                guard lineCount != lastDiagnosticLineCount
                    || storageUTF16Length != lastDiagnosticStorageLength
                    || filterKey != lastDiagnosticFilterKey
                else { return nil }
                lastDiagnosticLineCount = lineCount
                lastDiagnosticStorageLength = storageUTF16Length
                lastDiagnosticFilterKey = filterKey
                diagnosticTransitionSequence += 1
                return diagnosticTransitionSequence
            }

            func textView(
                _: NSTextView,
                clickedOnLink link: Any,
                at _: Int
            ) -> Bool {
                guard let url = link as? URL else { return false }
                NSWorkspace.shared.open(url)
                return true
            }
        }
    }

    final class ChatLogTextView: NSTextView {
        func configure(font: NSFont, background: NSColor) {
            isEditable = false
            isSelectable = true
            isRichText = true
            allowsUndo = false
            drawsBackground = background.alphaComponent > 0
            backgroundColor = background
            self.font = font
            linkTextAttributes = [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        }

        func updateBackground(_ background: NSColor) {
            drawsBackground = background.alphaComponent > 0
            if backgroundColor != background { backgroundColor = background }
        }
    }

    final class ChatLogScrollView: NSScrollView {
        var autoScrollThreshold: CGFloat = 32

        override func setFrameSize(_ newSize: NSSize) {
            let wasPinned = isScrolledToBottom()
            super.setFrameSize(newSize)
            if wasPinned {
                scrollToBottomSoon()
            }
        }

        func isScrolledToBottom() -> Bool {
            guard let documentView else { return true }
            let visible = contentView.documentVisibleRect
            return Self.isScrolledToBottom(
                documentHeight: documentView.frame.height,
                visibleOriginY: visible.origin.y,
                visibleHeight: visible.height,
                threshold: autoScrollThreshold
            )
        }

        nonisolated static func isScrolledToBottom(
            documentHeight: CGFloat,
            visibleOriginY: CGFloat,
            visibleHeight: CGFloat,
            threshold: CGFloat
        ) -> Bool {
            let distanceFromBottom = documentHeight - (visibleOriginY + visibleHeight)
            return distanceFromBottom < threshold
        }

        func healthSnapshot(
            reason: String,
            renderedLines: Int,
            storageUTF16Length: Int
        ) -> TextViewHealthSnapshot {
            let textView = documentView as? NSTextView
            let visible = contentView.documentVisibleRect
            let documentWidth = documentView?.frame.width ?? 0
            let documentHeight = documentView?.frame.height ?? 0
            let distanceFromBottom = documentHeight - (visible.origin.y + visible.height)
            let viewport = textView.flatMap { Self.viewportMetrics(for: $0) }
                ?? ViewportMetrics(
                    start: nil,
                    end: nil,
                    fragmentState: nil,
                    visualLines: nil,
                    topClip: nil,
                    bottomClip: nil
                )
            return TextViewHealthSnapshot(
                surface: "channels",
                reason: reason,
                renderedLines: renderedLines,
                storageUTF16Length: storageUTF16Length,
                textViewBoundsHeight: Double(textView?.bounds.height ?? 0),
                documentHeight: Double(documentHeight),
                visibleOriginY: Double(visible.origin.y),
                visibleHeight: Double(visible.height),
                distanceFromBottom: Double(distanceFromBottom),
                isPinnedToBottom: distanceFromBottom < autoScrollThreshold,
                isViewHidden: isHiddenOrHasHiddenAncestor,
                hasWindow: window != nil,
                textViewBoundsWidth: Double(textView?.bounds.width ?? 0),
                documentWidth: Double(documentWidth),
                visibleOriginX: Double(visible.origin.x),
                visibleWidth: Double(visible.width),
                textContainerWidth: Double(textView?.textContainer?.size.width ?? 0),
                usesTextLayoutManager: textView?.textLayoutManager != nil,
                viewportStartUTF16: viewport.start,
                viewportEndUTF16: viewport.end,
                topLayoutFragmentState: viewport.fragmentState,
                topVisualLineCount: viewport.visualLines,
                topVisualLineClip: viewport.topClip.map(Double.init),
                bottomVisualLineClip: viewport.bottomClip.map(Double.init),
                extra: "scroller \(hasVerticalScroller)"
            )
        }

        func scrollToBottomSoon() {
            scrollToBottom()
            DispatchQueue.main.async { [weak self] in
                self?.scrollToBottom()
            }
        }

        func restoreVisibleOrigin(_ origin: CGPoint) {
            let maxY = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
            contentView.scroll(to: CGPoint(x: 0, y: min(origin.y, maxY)))
            reflectScrolledClipView(contentView)
        }

        private func scrollToBottom() {
            (documentView as? NSTextView)?.scrollToEndOfDocument(nil)
            guard let documentView else { return }
            let visible = contentView.documentVisibleRect
            let targetY = max(documentView.frame.minY, documentView.frame.maxY - visible.height)
            contentView.scroll(to: CGPoint(x: 0, y: targetY))
            reflectScrolledClipView(contentView)
        }

        private struct ViewportMetrics {
            let start: Int?
            let end: Int?
            let fragmentState: Int?
            let visualLines: Int?
            let topClip: CGFloat?
            let bottomClip: CGFloat?
        }

        private static func viewportMetrics(for textView: NSTextView) -> ViewportMetrics? {
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager
            else { return nil }
            let documentStart = contentManager.documentRange.location
            let viewportRange = layoutManager.textViewportLayoutController.viewportRange
            let start = viewportRange.map {
                contentManager.offset(from: documentStart, to: $0.location)
            }
            let end = viewportRange.map {
                contentManager.offset(from: documentStart, to: $0.endLocation)
            }
            let visible = textView.enclosingScrollView?.contentView.documentVisibleRect
                ?? textView.visibleRect
            let origin = textView.textContainerOrigin
            let fragment = layoutManager.textLayoutFragment(for: CGPoint(
                x: max(0, visible.minX - origin.x + 1),
                y: max(0, visible.minY - origin.y + 0.5)
            ))
            let clipping = visualLineClipping(
                for: textView,
                layoutManager: layoutManager,
                visible: visible
            )
            return ViewportMetrics(
                start: start,
                end: end,
                fragmentState: fragment.map { Int($0.state.rawValue) },
                visualLines: fragment?.textLineFragments.count,
                topClip: clipping?.top,
                bottomClip: clipping?.bottom
            )
        }

        private static func visualLineClipping(
            for textView: NSTextView,
            layoutManager: NSTextLayoutManager,
            visible: CGRect
        ) -> (top: CGFloat, bottom: CGFloat)? {
            let documentBottom = textView.bounds.maxY
            guard documentBottom > 0 else { return nil }
            let topY = min(max(visible.minY + 0.5, 0.5), documentBottom - 0.5)
            let bottomY = min(max(visible.maxY - 0.5, 0.5), documentBottom - 0.5)
            guard let topLine = visualLine(at: topY, in: textView, layoutManager: layoutManager),
                  let bottomLine = visualLine(at: bottomY, in: textView, layoutManager: layoutManager)
            else { return nil }
            return (
                top: max(0, visible.minY - topLine.lowerBound),
                bottom: max(0, bottomLine.upperBound - visible.maxY)
            )
        }

        private static func visualLine(
            at documentY: CGFloat,
            in textView: NSTextView,
            layoutManager: NSTextLayoutManager
        ) -> ClosedRange<CGFloat>? {
            let origin = textView.textContainerOrigin
            let containerY = max(0, documentY - origin.y)
            guard let fragment = layoutManager.textLayoutFragment(
                for: CGPoint(x: 1, y: containerY)
            ), let line = fragment.textLineFragment(
                forVerticalOffset: containerY - fragment.layoutFragmentFrame.minY,
                requiresExactMatch: false
            ) else { return nil }
            let lineTop = origin.y
                + fragment.layoutFragmentFrame.minY
                + line.typographicBounds.minY
            return lineTop...(lineTop + line.typographicBounds.height)
        }
    }

#endif
