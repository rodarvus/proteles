import MudCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Transparent interaction regions over a miniwindow's hotspots (Phase 2). Each
/// hotspot maps mouse-over / down / up gestures to the plugin's named Lua
/// callbacks, emitted as ``MiniWindowEvent``s the session dispatches back into
/// the owning plugin's runtime.
///
/// Mouse-over only fires on enter/exit transitions (SwiftUI `onHover`), so the
/// per-pixel `MouseOver` flood the plan warns about never reaches the actor.
struct MiniWindowHotspotLayer: View {
    let scene: MiniWindowScene
    let onEvent: (MiniWindowEvent) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(scene.hotspots, id: \.id) { hotspot in
                region(hotspot)
            }
        }
        .frame(width: CGFloat(scene.width), height: CGFloat(scene.height), alignment: .topLeading)
    }

    @ViewBuilder
    private func region(_ hotspot: MiniWindowHotspot) -> some View {
        let frame = rect(hotspot)
        if frame.width > 0, frame.height > 0 {
            HotspotRegion(scene: scene, hotspot: hotspot, onEvent: onEvent)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
    }

    private func rect(_ hotspot: MiniWindowHotspot) -> CGRect {
        let left = CGFloat(hotspot.left)
        let top = CGFloat(hotspot.top)
        let right = MiniWindowScene.fix(hotspot.right, extent: scene.width)
        let bottom = MiniWindowScene.fix(hotspot.bottom, extent: scene.height)
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }
}

/// One hotspot's interactive surface. Split out so the press/hover `@State`
/// is per-hotspot.
private struct HotspotRegion: View {
    let scene: MiniWindowScene
    let hotspot: MiniWindowHotspot
    let onEvent: (MiniWindowEvent) -> Void
    @State private var pressed = false

    var body: some View {
        #if os(macOS)
            HotspotEventBridge(scene: scene, hotspot: hotspot, onEvent: onEvent)
                .help(hotspot.tooltip)
        #else
            Color.clear
                .contentShape(Rectangle())
                .help(hotspot.tooltip)
                .onHover { inside in
                    if inside {
                        fire(.mouseOver, hotspot.mouseOver, x: hotspot.left, y: hotspot.top)
                    } else {
                        fire(.cancelMouseOver, hotspot.cancelMouseOver, x: hotspot.left, y: hotspot.top)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = windowPoint(value.location)
                            if pressed {
                                fire(.dragMove, hotspot.dragMove, x: point.x, y: point.y)
                            } else {
                                pressed = true
                                fire(.mouseDown, hotspot.mouseDown, x: point.x, y: point.y)
                            }
                        }
                        .onEnded { value in
                            let point = windowPoint(value.location)
                            pressed = false
                            fire(.mouseUp, hotspot.mouseUp, x: point.x, y: point.y)
                            fire(.dragRelease, hotspot.dragRelease, x: point.x, y: point.y)
                        }
                )
        #endif
    }

    /// Emit an event only when the plugin registered a callback for it (MUSHclient
    /// passes "" for "no handler").
    private func fire(_ kind: MiniWindowEvent.Kind, _ callback: String, x: Int, y: Int) {
        guard !callback.isEmpty else { return }
        onEvent(MiniWindowEvent(
            windowName: scene.name,
            pluginID: scene.pluginID,
            hotspotID: hotspot.id,
            kind: kind,
            callback: callback,
            flags: 0, // modifier/button decoding deferred (spike)
            x: x,
            y: y
        ))
    }

    private func windowPoint(_ location: CGPoint) -> (x: Int, y: Int) {
        (
            x: hotspot.left + Int(location.x.rounded(.down)),
            y: hotspot.top + Int(location.y.rounded(.down))
        )
    }
}

#if os(macOS)
    private struct HotspotEventBridge: NSViewRepresentable {
        let scene: MiniWindowScene
        let hotspot: MiniWindowHotspot
        let onEvent: (MiniWindowEvent) -> Void

        func makeNSView(context _: Context) -> HotspotEventView {
            let view = HotspotEventView()
            view.configure(scene: scene, hotspot: hotspot, onEvent: onEvent)
            return view
        }

        func updateNSView(_ view: HotspotEventView, context _: Context) {
            view.configure(scene: scene, hotspot: hotspot, onEvent: onEvent)
        }
    }

    private final class HotspotEventView: NSView {
        private var scene: MiniWindowScene?
        private var hotspot: MiniWindowHotspot?
        private var onEvent: ((MiniWindowEvent) -> Void)?
        private var tracking: NSTrackingArea?

        override var acceptsFirstResponder: Bool {
            true
        }

        func configure(
            scene: MiniWindowScene,
            hotspot: MiniWindowHotspot,
            onEvent: @escaping (MiniWindowEvent) -> Void
        ) {
            self.scene = scene
            self.hotspot = hotspot
            self.onEvent = onEvent
            toolTip = hotspot.tooltip.isEmpty ? nil : hotspot.tooltip
            needsDisplay = true
        }

        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            tracking = area
            super.updateTrackingAreas()
        }

        override func mouseEntered(with _: NSEvent) {
            fire(.mouseOver, callback: hotspot?.mouseOver ?? "", point: .zero, flags: 0)
        }

        override func mouseExited(with _: NSEvent) {
            fire(
                .cancelMouseOver,
                callback: hotspot?.cancelMouseOver ?? "",
                point: .zero,
                flags: 0
            )
        }

        override func mouseDown(with event: NSEvent) {
            fire(.mouseDown, callback: hotspot?.mouseDown ?? "", point: localPoint(event), flags: 0)
        }

        override func mouseDragged(with event: NSEvent) {
            fire(.dragMove, callback: hotspot?.dragMove ?? "", point: localPoint(event), flags: 0)
        }

        override func mouseUp(with event: NSEvent) {
            let point = localPoint(event)
            fire(.mouseUp, callback: hotspot?.mouseUp ?? "", point: point, flags: 0)
            fire(.dragRelease, callback: hotspot?.dragRelease ?? "", point: point, flags: 0)
        }

        override func scrollWheel(with event: NSEvent) {
            fire(
                .scrollwheel,
                callback: hotspot?.scrollwheel ?? "",
                point: localPoint(event),
                flags: scrollFlags(event)
            )
        }

        private func fire(_ kind: MiniWindowEvent.Kind, callback: String, point: CGPoint, flags: Int) {
            guard let scene, let hotspot, !callback.isEmpty else { return }
            onEvent?(MiniWindowEvent(
                windowName: scene.name,
                pluginID: scene.pluginID,
                hotspotID: hotspot.id,
                kind: kind,
                callback: callback,
                flags: flags,
                x: hotspot.left + Int(point.x.rounded(.down)),
                y: hotspot.top + Int(point.y.rounded(.down))
            ))
        }

        private func localPoint(_ event: NSEvent) -> CGPoint {
            let point = convert(event.locationInWindow, from: nil)
            return CGPoint(x: point.x, y: bounds.height - point.y)
        }

        private func scrollFlags(_ event: NSEvent) -> Int {
            let delta = event.scrollingDeltaY == 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            let magnitude = max(120, Int(abs(delta * 120).rounded()))
            let direction = delta < 0 ? 0x100 : 0
            return direction | (magnitude << 16)
        }
    }
#endif
