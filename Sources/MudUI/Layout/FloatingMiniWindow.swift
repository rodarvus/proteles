import MudCore
import SwiftUI

/// A compact, fixed floating miniwindow pinned to the top-right of the main
/// window, layered over the game output (UI revamp — the Text Map floats here
/// by default). Sized to its content (capped), with a slim header to dock or
/// hide it. Not draggable/resizable by design — it's a HUD, not a free window.
public struct FloatingMiniWindow<Content: View>: View {
    private let kind: PanelKind
    private let onDock: () -> Void
    private let onClose: () -> Void
    @ViewBuilder private let content: Content
    @State private var hovering = false

    public init(
        kind: PanelKind,
        onDock: @escaping () -> Void,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.kind = kind
        self.onDock = onDock
        self.onClose = onClose
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: 340, maxHeight: 360)
        .fixedSize() // size to content, within the caps above
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(kind.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onDock) {
                Image(systemName: "rectangle.portrait.and.arrow.forward").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(hovering ? 1 : 0)
            .help("Dock \(kind.title) into the main window")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(hovering ? 1 : 0)
            .help("Hide \(kind.title)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
    }
}

/// Stack of all floating miniwindows, pinned top-right over the output. The app
/// supplies each panel's view via `content`.
public struct FloatingPanelLayer: View {
    @Bindable private var store: LayoutStore
    private let content: (PanelKind) -> AnyView

    public init(store: LayoutStore, content: @escaping (PanelKind) -> AnyView) {
        self.store = store
        self.content = content
    }

    public var body: some View {
        // Stable order so windows don't jump as the set changes.
        let kinds = PanelKind.allCases.filter { store.floating.contains($0) }
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(kinds) { kind in
                FloatingMiniWindow(
                    kind: kind,
                    onDock: { store.dockFloating(kind) },
                    onClose: { store.toggle(kind) },
                    content: { content(kind) }
                )
            }
        }
        .padding(10)
    }
}
