import CoreGraphics
import MudCore
import SwiftUI

/// In-window floating miniwindow chrome (the floating-miniwindow rework, GH #33):
/// a compact header (drag handle · dock · close) over a panel, a resize grip,
/// and self-measurement. Positioning is owned by ``FloatingPanelLayer`` (anchor +
/// offset); this view renders, reports its size, and emits drag/resize deltas.
public struct FloatingMiniWindow<Content: View>: View {
    private let kind: PanelKind
    private let hugContent: Bool
    private let explicitSize: CGSize?
    private let onMoved: (CGSize) -> Void // total drag translation, on end
    private let onResized: (CGSize) -> Void // new explicit size, live
    private let onMeasured: (CGSize) -> Void // measured size, for snap math
    private let onDock: () -> Void
    private let onClose: () -> Void
    @ViewBuilder private let content: Content

    @State private var hovering = false
    @State private var measured: CGSize = .zero
    @State private var resizeBase: CGSize?
    @GestureState private var dragTranslation: CGSize = .zero

    public init(
        kind: PanelKind,
        hugContent: Bool,
        explicitSize: CGSize?,
        onMoved: @escaping (CGSize) -> Void,
        onResized: @escaping (CGSize) -> Void,
        onMeasured: @escaping (CGSize) -> Void,
        onDock: @escaping () -> Void,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.kind = kind
        self.hugContent = hugContent
        self.explicitSize = explicitSize
        self.onMoved = onMoved
        self.onResized = onResized
        self.onMeasured = onMeasured
        self.onDock = onDock
        self.onClose = onClose
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .modifier(MiniWindowSizing(hugContent: hugContent, explicitSize: explicitSize))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .background(sizeReader)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .offset(x: dragTranslation.width, y: dragTranslation.height)
        .onHover { hovering = $0 }
    }

    /// Slim title bar — and the drag surface for repositioning the window.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.systemImage).font(.caption2).foregroundStyle(.secondary)
            Text(kind.title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            iconButton("rectangle.portrait.and.arrow.forward", "Dock \(kind.title)", action: onDock)
            iconButton("xmark", "Hide \(kind.title)", action: onClose)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
        .contentShape(Rectangle())
        .gesture(
            // Global space: the window is moved by `.offset`, so a `.local` drag
            // would feed back on itself (jitter + tiny travel — GH follow-up).
            DragGesture(coordinateSpace: .global)
                .updating($dragTranslation) { value, state, _ in state = value.translation }
                .onEnded { onMoved($0.translation) }
        )
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption2.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .opacity(hovering ? 1 : 0)
        .help(help)
    }

    /// Bottom-right resize grip: drags set an explicit size (converting a
    /// content-hugging window to a fixed one on first resize).
    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(4)
            .opacity(hovering ? 1 : 0)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let base = resizeBase ?? explicitSize ?? measured
                        if resizeBase == nil { resizeBase = base }
                        onResized(CGSize(
                            width: max(140, base.width + value.translation.width),
                            height: max(90, base.height + value.translation.height)
                        ))
                    }
                    .onEnded { _ in resizeBase = nil }
            )
            .help("Resize \(kind.title)")
    }

    /// Reports the rendered size up to the layer (macOS-14-safe; no
    /// onGeometryChange). Used only for drag-end snap math.
    private var sizeReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { report(geo.size) }
                .onChange(of: geo.size) { _, new in report(new) }
        }
    }

    private func report(_ size: CGSize) {
        guard size != measured else { return }
        measured = size
        onMeasured(size)
    }
}

/// Sizing policy: explicit size wins; otherwise content-hug panels hug, and
/// fill-style panels get a floor so they don't collapse before they're sized.
private struct MiniWindowSizing: ViewModifier {
    let hugContent: Bool
    let explicitSize: CGSize?

    func body(content: Content) -> some View {
        if let explicitSize {
            content.frame(width: explicitSize.width, height: explicitSize.height)
        } else if hugContent {
            content.fixedSize()
        } else {
            content.frame(minWidth: 240, minHeight: 160)
        }
    }
}

/// Overlay layer of all floating miniwindows inside the main window. Each window
/// is anchored to a container corner by its ``FloatingPlacement`` (alignment +
/// inward offset, so no size is needed to lay it out); dragging the header frees
/// it, and on release it snaps to the nearest corner or sibling edge.
public struct FloatingPanelLayer: View {
    @Bindable private var store: LayoutStore
    private let content: (PanelKind) -> AnyView
    @State private var measured: [PanelKind: CGSize] = [:]

    public init(store: LayoutStore, content: @escaping (PanelKind) -> AnyView) {
        self.store = store
        self.content = content
    }

    /// Stable order so windows don't restack as the set changes.
    private var kinds: [PanelKind] {
        PanelKind.allCases.filter { store.floating[$0] != nil }
    }

    public var body: some View {
        GeometryReader { geo in
            let container = geo.size
            ZStack(alignment: .topLeading) {
                ForEach(kinds, id: \.self) { kind in
                    if let placement = store.floating[kind] {
                        miniWindow(kind, placement, container)
                    }
                }
            }
        }
    }

    private func miniWindow(
        _ kind: PanelKind,
        _ placement: FloatingPlacement,
        _ container: CGSize
    ) -> some View {
        FloatingMiniWindow(
            kind: kind,
            hugContent: kind.floatingHugsContent,
            explicitSize: placement.size,
            onMoved: { translation in move(kind, placement, container, translation) },
            onResized: { size in
                var next = placement
                next.size = size
                store.setFloatingPlacement(kind, next)
            },
            onMeasured: { measured[kind] = $0 },
            onDock: { store.dockFloating(kind) },
            onClose: { store.toggle(kind) },
            content: { content(kind) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.anchor.alignment)
        .offset(restingOffset(placement))
    }

    /// The signed inward offset for `.offset`, given the anchor corner.
    private func restingOffset(_ placement: FloatingPlacement) -> CGSize {
        CGSize(
            width: placement.anchor.isLeading ? placement.offset.width : -placement.offset.width,
            height: placement.anchor.isTop ? placement.offset.height : -placement.offset.height
        )
    }

    /// Resolve the resting rect (for snap math) from placement + measured size.
    private func rect(_ kind: PanelKind, _ placement: FloatingPlacement, _ container: CGSize) -> CGRect {
        let size = placement.size ?? measured[kind] ?? CGSize(width: 220, height: 160)
        return placement.rect(in: container, content: size)
    }

    /// Drag ended: offset the resting rect by the translation, snap to the
    /// nearest corner / sibling, and persist the new anchor + offset.
    private func move(
        _ kind: PanelKind,
        _ placement: FloatingPlacement,
        _ container: CGSize,
        _ translation: CGSize
    ) {
        let moved = rect(kind, placement, container)
            .offsetBy(dx: translation.width, dy: translation.height)
        let siblings = kinds
            .filter { $0 != kind }
            .compactMap { other in store.floating[other].map { rect(other, $0, container) } }
        let snapped = FloatingSnap.snap(rect: moved, in: container, siblings: siblings)
        var next = placement
        next.anchor = snapped.anchor
        next.offset = snapped.offset
        store.setFloatingPlacement(kind, next)
    }
}

private extension FloatingAnchor {
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}
