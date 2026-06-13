import MudCore
import SwiftUI

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
        Color.clear
            .contentShape(Rectangle())
            .help(hotspot.tooltip)
            .onHover { inside in
                if inside {
                    fire(.mouseOver, hotspot.mouseOver)
                } else {
                    fire(.cancelMouseOver, hotspot.cancelMouseOver)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        fire(.mouseDown, hotspot.mouseDown)
                    }
                    .onEnded { _ in
                        pressed = false
                        fire(.mouseUp, hotspot.mouseUp)
                    }
            )
    }

    /// Emit an event only when the plugin registered a callback for it (MUSHclient
    /// passes "" for "no handler").
    private func fire(_ kind: MiniWindowEvent.Kind, _ callback: String) {
        guard !callback.isEmpty else { return }
        onEvent(MiniWindowEvent(
            windowName: scene.name,
            pluginID: scene.pluginID,
            hotspotID: hotspot.id,
            kind: kind,
            callback: callback,
            flags: 0 // modifier/button decoding deferred (spike)
        ))
    }
}
