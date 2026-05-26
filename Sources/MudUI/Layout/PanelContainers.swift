import MudCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// A resizable row/column of child nodes (a `.split`). Sizes each child from
/// its fraction and draws a draggable divider between them; a drag rewrites the
/// fractions through the ``LayoutStore``. The native equivalent of Geyser's
/// adjustable H/V box.
struct SplitContainer: View {
    let axis: LayoutAxis
    let items: [PanelLayout.Item]
    let path: [Int]
    let store: LayoutStore
    let child: (PanelLayout, [Int]) -> AnyView

    @State private var liveFractions: [Double]?
    @State private var dragBase: [Double]?
    @State private var activeDivider: Int?

    private let dividerThickness: CGFloat = 7
    private let minPanelPoints: CGFloat = 90

    var body: some View {
        GeometryReader { geo in
            let total = max(1, axis == .horizontal ? geo.size.width : geo.size.height)
            let fractions = liveFractions ?? items.map(\.fraction)
            let available = max(1, total - CGFloat(items.count - 1) * dividerThickness)
            stack {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    child(item.node, path + [index])
                        .frame(
                            width: axis == .horizontal ? fractions[index] * available : nil,
                            height: axis == .vertical ? fractions[index] * available : nil
                        )
                        .frame(
                            maxWidth: axis == .vertical ? .infinity : nil,
                            maxHeight: axis == .horizontal ? .infinity : nil
                        )
                        .clipped()
                    if index < items.count - 1 {
                        divider(index: index, total: available)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stack(@ViewBuilder _ content: () -> some View) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) { content() }
        } else {
            VStack(spacing: 0) { content() }
        }
    }

    private func divider(index: Int, total: CGFloat) -> some View {
        Rectangle()
            .fill(activeDivider == index ? Color.accentColor.opacity(0.6) : Color(.separatorColor))
            .frame(
                width: axis == .horizontal ? dividerThickness : nil,
                height: axis == .vertical ? dividerThickness : nil
            )
            .frame(
                maxWidth: axis == .vertical ? .infinity : nil,
                maxHeight: axis == .horizontal ? .infinity : nil
            )
            .contentShape(Rectangle())
            .onHover { inside in
                activeDivider = inside ? index : (activeDivider == index ? nil : activeDivider)
                #if os(macOS)
                    if inside {
                        (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                    } else {
                        NSCursor.arrow.set()
                    }
                #endif
            }
            .gesture(dragGesture(index: index, total: total))
            .help("Drag to resize")
    }

    private func dragGesture(index: Int, total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let base = dragBase ?? items.map(\.fraction)
                if dragBase == nil { dragBase = base }
                activeDivider = index
                let raw = (axis == .horizontal ? value.translation.width : value.translation.height) / total
                let minFraction = Double(minPanelPoints / total)
                let lower = -(base[index] - minFraction)
                let upper = base[index + 1] - minFraction
                let delta = max(min(raw, upper), lower)
                var next = base
                next[index] = base[index] + delta
                next[index + 1] = base[index + 1] - delta
                liveFractions = next
            }
            .onEnded { _ in
                if let live = liveFractions { store.setFractions(live, at: path) }
                liveFractions = nil
                dragBase = nil
                activeDivider = nil
            }
    }
}

/// Several panels stacked in one slot with a compact tab strip — the density
/// trick (e.g. S&D and Text Map sharing a region).
struct TabContainer: View {
    let panels: [PanelKind]
    let selection: Int
    let store: LayoutStore
    let path: [Int]
    let content: (PanelKind) -> AnyView

    var body: some View {
        let selected = min(max(0, selection), panels.count - 1)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(panels.enumerated()), id: \.offset) { index, kind in
                    let isSelected = index == selected
                    Button {
                        store.selectTab(index, at: path)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind.systemImage).font(.caption2)
                            Text(kind.shortTitle)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 4)
                Button {
                    store.close(panels[selected])
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .help("Hide \(panels[selected].title)")
            }
            .background(.bar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator).frame(height: 1)
            }
            content(panels[selected])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
