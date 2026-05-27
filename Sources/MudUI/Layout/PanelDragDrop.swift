import MudCore
import SwiftUI
import UniformTypeIdentifiers

/// Drag-to-redock (`docs/UI_REVAMP.md`). A panel's chrome / tab is a drag
/// source carrying its ``PanelKind``; every panel is a drop target that splits
/// (edge) or tab-merges (centre) when another panel is dropped on it. The pure
/// tree mutation lives in ``PanelLayout/moving(_:onto:zone:)``; this is just the
/// SwiftUI glue (payload, hit-zone, highlight).
extension View {
    /// Make this view a drag source for `kind` (grab a panel by its header/tab).
    func panelDragSource(_ kind: PanelKind) -> some View {
        onDrag {
            NSItemProvider(object: kind.rawValue as NSString)
        } preview: {
            Label(kind.title, systemImage: kind.systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Make this view a drop target that re-docks a dragged panel onto `target`.
    func panelDropTarget(_ target: PanelKind, store: LayoutStore) -> some View {
        modifier(PanelDropTarget(target: target, store: store))
    }
}

/// Wraps a panel so it accepts a dropped ``PanelKind`` and shows where it'll
/// land. Tracks size (to classify the point) and the live highlight zone.
private struct PanelDropTarget: ViewModifier {
    let target: PanelKind
    let store: LayoutStore
    @State private var size: CGSize = .zero
    @State private var activeZone: DropZone?

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { size = geo.size }
                        .onChange(of: geo.size) { _, new in size = new }
                }
            )
            .overlay {
                if let zone = activeZone {
                    DropZoneHighlight(zone: zone)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onDrop(of: [.plainText], delegate: PanelDropDelegate(
                target: target,
                store: store,
                size: { size },
                activeZone: $activeZone
            ))
    }
}

/// Bridges SwiftUI drop callbacks to the layout move. The dragged panel kind
/// arrives as plain text; the drop point + panel size pick the ``DropZone``.
private struct PanelDropDelegate: DropDelegate {
    let target: PanelKind
    let store: LayoutStore
    let size: () -> CGSize
    @Binding var activeZone: DropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        activeZone = zone(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        activeZone = zone(at: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        activeZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let landingZone = zone(at: info.location)
        activeZone = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let store = store
        let target = target
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String, let dragged = PanelKind(rawValue: raw) else { return }
            Task { @MainActor in store.move(dragged, onto: target, zone: landingZone) }
        }
        return true
    }

    private func zone(at point: CGPoint) -> DropZone {
        let bounds = size()
        return DropZone.at(
            x: Double(point.x),
            y: Double(point.y),
            width: Double(bounds.width),
            height: Double(bounds.height)
        )
    }
}

/// Translucent overlay showing the region a dropped panel will occupy: half the
/// panel for an edge, the whole panel for a centre (tab-merge).
private struct DropZoneHighlight: View {
    let zone: DropZone

    var body: some View {
        GeometryReader { geo in
            let rect = frame(in: geo.size)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func frame(in size: CGSize) -> CGRect {
        let fullW = size.width, fullH = size.height
        switch zone {
        case .center: return CGRect(x: 0, y: 0, width: fullW, height: fullH)
        case .leading: return CGRect(x: 0, y: 0, width: fullW / 2, height: fullH)
        case .trailing: return CGRect(x: fullW / 2, y: 0, width: fullW / 2, height: fullH)
        case .top: return CGRect(x: 0, y: 0, width: fullW, height: fullH / 2)
        case .bottom: return CGRect(x: 0, y: fullH / 2, width: fullW, height: fullH / 2)
        }
    }
}
