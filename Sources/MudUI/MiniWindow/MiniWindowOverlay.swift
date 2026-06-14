import MudCore
import SwiftUI

/// The floating layer of live MUSHclient miniwindows, composited over the MUD
/// output. Each window is positioned by its own MUSHclient coordinates (the
/// position constant, or absolute `left`/`top`) within the output bounds —
/// plugins own placement, exactly as in MUSHclient.
///
/// A light rounded clip + drop shadow makes the frameless GDI-era windows look
/// native without altering their 1:1 pixel geometry (the "nicer than MUSHclient"
/// touch from the plan). Self-contained: it owns the ``MiniWindowStore``,
/// subscribes to the session's scene stream, and routes hotspot gestures back to
/// the session — so the host view only adds `.overlay { MiniWindowOverlay(session:) }`.
/// With no hotspots a window passes clicks through, so output stays selectable.
public struct MiniWindowOverlay: View {
    private let session: SessionController
    @State private var store = MiniWindowStore()

    public init(session: SessionController) {
        self.session = session
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(visibleScenes) { scene in
                    MiniWindowFrame(scene: scene, store: store, container: geo.size) { event in
                        Task { await session.dispatchMiniWindowEvent(event) }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .task { await store.run(session: session) }
    }

    private var visibleScenes: [MiniWindowScene] {
        store.orderedScenes.filter { $0.visible && $0.width > 0 && $0.height > 0 }
    }
}

/// One positioned, draggable miniwindow. Renders the scene + hotspots, and lets
/// the user drag the window by any non-hotspot area (the hotspot layer, on top,
/// claims clicks on its regions first). The dragged position is persisted, so it
/// returns there next launch — a Proteles nicety the GDI original lacks. Held in
/// its own view so the live-drag `@GestureState` is per-window.
private struct MiniWindowFrame: View {
    let scene: MiniWindowScene
    let store: MiniWindowStore
    let container: CGSize
    let onEvent: (MiniWindowEvent) -> Void
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        let base = store.position(for: scene) ?? scene.origin(in: container)
        MiniWindowCanvasView(
            scene: scene,
            imageProvider: { store.image(pluginID: scene.pluginID, imageID: $0) }
        )
        .frame(width: CGFloat(scene.width), height: CGFloat(scene.height))
        .overlay { MiniWindowHotspotLayer(scene: scene, onEvent: onEvent) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        .offset(x: base.x + drag.width, y: base.y + drag.height)
        // Global space so moving the view via `.offset` doesn't feed back into
        // the drag (the FloatingMiniWindow lesson). A small threshold lets a
        // click on a hotspot still register as a click, not a drag.
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    store.setPosition(clamp(base: base, translation: value.translation), for: scene)
                }
        )
    }

    /// Keep the dragged window within the output bounds (its top-left stays on
    /// screen, leaving room for the window itself).
    private func clamp(base: CGPoint, translation: CGSize) -> CGPoint {
        let maxX = max(0, container.width - CGFloat(scene.width))
        let maxY = max(0, container.height - CGFloat(scene.height))
        return CGPoint(
            x: min(max(0, base.x + translation.width), maxX),
            y: min(max(0, base.y + translation.height), maxY)
        )
    }
}
