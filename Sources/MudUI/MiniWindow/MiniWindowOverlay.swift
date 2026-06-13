import MudCore
import SwiftUI

/// The floating layer of live MUSHclient miniwindows, composited over the MUD
/// output. Each window is positioned by its own MUSHclient coordinates (the
/// position constant, or absolute `left`/`top`) within the output bounds —
/// plugins own placement, exactly as in MUSHclient.
///
/// A light rounded clip + drop shadow makes the frameless GDI-era windows look
/// native without altering their 1:1 pixel geometry (the "nicer than MUSHclient"
/// touch from the plan). Hotspot interactivity (Phase 2) is layered on top via
/// `onEvent`; with no hotspots a window is transparent to the mouse so the
/// output underneath stays clickable/selectable.
public struct MiniWindowOverlay: View {
    private let store: MiniWindowStore
    private let onEvent: (MiniWindowEvent) -> Void

    public init(store: MiniWindowStore, onEvent: @escaping (MiniWindowEvent) -> Void = { _ in }) {
        self.store = store
        self.onEvent = onEvent
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(visibleScenes) { scene in
                    windowView(scene, container: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // The layer itself never intercepts; only hotspot regions do (Phase 2).
        .allowsHitTesting(true)
    }

    private var visibleScenes: [MiniWindowScene] {
        store.orderedScenes.filter { $0.visible && $0.width > 0 && $0.height > 0 }
    }

    private func windowView(_ scene: MiniWindowScene, container: CGSize) -> some View {
        let origin = scene.origin(in: container)
        return MiniWindowCanvasView(
            scene: scene,
            imageProvider: { store.image(pluginID: scene.pluginID, imageID: $0) }
        )
        .frame(width: CGFloat(scene.width), height: CGFloat(scene.height))
        .overlay { MiniWindowHotspotLayer(scene: scene, onEvent: onEvent) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        .offset(x: origin.x, y: origin.y)
    }
}
