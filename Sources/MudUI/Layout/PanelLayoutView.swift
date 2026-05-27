import MudCore
import SwiftUI

/// Renders a ``PanelLayout`` tree as a tiled, resizable dock (the UI revamp —
/// `docs/UI_REVAMP.md`). The app supplies the actual view for each
/// ``PanelKind`` via `content`; this engine handles splits (draggable
/// dividers), tab groups, panel chrome (title + close), and writes layout
/// changes back through the ``LayoutStore``.
public struct PanelLayoutView: View {
    @Bindable private var store: LayoutStore
    private let content: (PanelKind) -> AnyView
    private let onDetach: (PanelKind) -> Void

    /// - Parameters:
    ///   - store: the live layout (bound, so resizes/toggles re-render).
    ///   - content: maps a panel kind to its view. `output` is rendered raw
    ///     (it owns the game text + input + gauges); every other kind is wrapped
    ///     in chrome with a title and close button.
    ///   - onDetach: tear a panel into its own window (the app opens it).
    public init(
        store: LayoutStore,
        onDetach: @escaping (PanelKind) -> Void = { _ in },
        content: @escaping (PanelKind) -> AnyView
    ) {
        self.store = store
        self.onDetach = onDetach
        self.content = content
    }

    /// The panel-arrangement menu shared by chrome + tab strips: float top-right
    /// or open in a separate window.
    static func arrangeMenu(
        _ kind: PanelKind,
        store: LayoutStore,
        onDetach: @escaping (PanelKind) -> Void
    ) -> some View {
        Menu {
            Button {
                store.float(kind)
            } label: {
                Label("Float Top-Right", systemImage: "pip")
            }
            Button {
                onDetach(kind)
            } label: {
                Label("Open in Window", systemImage: "macwindow.on.rectangle")
            }
        } label: {
            Image(systemName: "ellipsis").font(.caption2.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move \(kind.title) — float or open in a window")
    }

    public var body: some View {
        render(store.layout, path: [])
    }

    /// Recursively build the view for a node. `AnyView` is required because a
    /// SwiftUI view type can't reference itself recursively.
    func render(_ layout: PanelLayout, path: [Int]) -> AnyView {
        switch layout {
        case .leaf(let kind):
            AnyView(panel(kind))
        case .tabs(let panels, let selection):
            AnyView(TabContainer(
                panels: panels,
                selection: selection,
                store: store,
                path: path,
                onDetach: onDetach,
                content: content
            ))
        case .split(let axis, let items):
            AnyView(SplitContainer(
                axis: axis,
                items: items,
                path: path,
                store: store,
                child: { node, childPath in render(node, path: childPath) }
            ))
        }
    }

    /// A leaf panel: `output` renders raw (plus a small drag grip so it can be
    /// re-docked too); everything else gets chrome. Every panel is a drop target
    /// for drag-to-redock.
    private func panel(_ kind: PanelKind) -> some View {
        Group {
            if kind == .output {
                content(kind)
                    .overlay(alignment: .topTrailing) { outputDragGrip }
            } else {
                PanelChrome(
                    kind: kind,
                    onClose: { store.close(kind) },
                    arrangeMenu: { AnyView(Self.arrangeMenu(kind, store: store, onDetach: onDetach)) },
                    content: { content(kind) }
                )
            }
        }
        .panelDropTarget(kind, store: store)
    }

    /// A small drag handle for the (chrome-less) output panel, so it can be
    /// moved like any other. Top-trailing keeps it clear of the input field.
    private var outputDragGrip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(5)
            .background(.bar, in: RoundedRectangle(cornerRadius: 5))
            .padding(6)
            .panelDragSource(.output)
            .help("Drag to move the game window")
    }
}

/// Chrome for a docked panel. There's no title bar — to save vertical space the
/// controls (drag-to-move grip, arrange menu, close) are embedded as a compact
/// capsule overlaid on the top-right of the panel's own content, revealed on
/// hover. Each panel already carries its own header (room/campaign/channel), so
/// a separate title row would be redundant.
struct PanelChrome<Content: View>: View {
    let kind: PanelKind
    let onClose: () -> Void
    let arrangeMenu: () -> AnyView
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) { controls }
            .onHover { hovering = $0 }
    }

    /// Floating control capsule (drag grip · arrange · close), shown on hover so
    /// it stays out of the way until needed. The grip is the drag source for
    /// drag-to-redock; the whole capsule is draggable too.
    private var controls: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            arrangeMenu()
                .foregroundStyle(.secondary)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide \(kind.title)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .contentShape(Capsule())
        .panelDragSource(kind)
        .help("Drag to move \(kind.title)")
        .padding(6)
        .opacity(hovering ? 1 : 0)
    }
}
