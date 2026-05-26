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

    /// - Parameters:
    ///   - store: the live layout (bound, so resizes/toggles re-render).
    ///   - content: maps a panel kind to its view. `output` is rendered raw
    ///     (it owns the game text + input + gauges); every other kind is wrapped
    ///     in chrome with a title and close button.
    public init(store: LayoutStore, content: @escaping (PanelKind) -> AnyView) {
        self.store = store
        self.content = content
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

    /// A leaf panel: `output` renders raw; everything else gets chrome.
    @ViewBuilder
    private func panel(_ kind: PanelKind) -> some View {
        if kind == .output {
            content(kind)
        } else {
            PanelChrome(kind: kind, onClose: { store.close(kind) }, content: { content(kind) })
        }
    }
}

/// A panel's title bar (icon + title + close) above its content. Gives every
/// non-output panel a consistent, discoverable header.
struct PanelChrome<Content: View>: View {
    let kind: PanelKind
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: kind.systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(kind.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .help("Hide \(kind.title)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator).frame(height: 1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onHover { hovering = $0 }
    }
}
