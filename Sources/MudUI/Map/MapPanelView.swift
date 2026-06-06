import MudCore
import SwiftUI

/// The graphical GMCP map (docked Map panel): renders the ``MapLayout``
/// published by the live ``Mapper`` as a vector map — fan-out BFS grid, room
/// tiles coloured by type, up/down chevrons, one-way arrows. Pan (drag),
/// zoom (pinch / toolbar), hover for a tooltip, click a room to speedwalk, or
/// right-click for the full action menu.
public struct MapPanelView: View {
    @Bindable private var model: MapPanelModel

    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var hovered: PlacedRoom?
    @State private var editingNote: PlacedRoom?
    @State private var noteText = ""

    public init(model: MapPanelModel) {
        self.model = model
    }

    public var body: some View {
        // Graphical only — the server ASCII map now lives in the floating Text
        // Map window (no in-panel Graphical/Text switch needed any more).
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { model.start() }
            .alert(
                model.importAlert?.title ?? "",
                isPresented: Binding(
                    get: { model.importAlert != nil },
                    set: { if !$0 { model.importAlert = nil } }
                )
            ) {
                Button("OK") { model.importAlert = nil }
            } message: {
                Text(model.importAlert?.message ?? "")
            }
    }

    /// The active map view: the graphical layout, or its empty state.
    @ViewBuilder
    private var content: some View {
        if model.layout.isEmpty {
            emptyState
        } else {
            mapBody
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "No Map Yet",
                systemImage: "map",
                description: Text("The map fills in as you explore — or import an existing database.")
            )
            Button {
                model.importDatabase()
            } label: {
                Label("Import Map Database…", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var mapBody: some View {
        GeometryReader { geo in
            let layout = model.layout
            let geometry = MapGeometry(size: geo.size, zoom: zoom, pan: pan)
            ZStack {
                MapPalette.background
                Canvas { context, _ in
                    for link in layout.links {
                        draw(link, in: context, geometry: geometry)
                    }
                    for room in layout.rooms {
                        draw(room, in: context, geometry: geometry)
                    }
                    for marker in layout.areaExits {
                        draw(marker, in: context, geometry: geometry)
                    }
                }
                pulse(for: layout, geometry: geometry)
            }
            .contentShape(Rectangle())
            .gesture(panGesture)
            .simultaneousGesture(zoomGesture)
            .simultaneousGesture(tapGesture(layout: layout, geometry: geometry))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = room(at: point, layout: layout, geometry: geometry)
                case .ended:
                    hovered = nil
                }
            }
            .contextMenu { contextMenu }
            .overlay(alignment: .top) { header(layout) }
            .overlay(alignment: .bottomLeading) { infoBar }
            .overlay(alignment: .bottomTrailing) { toolbar }
            .onChange(of: layout.current) {
                // Recenter on the new current room.
                pan = .zero
                panStart = .zero
            }
            .alert(
                "Note for \(editingNote?.name ?? "room")",
                isPresented: Binding(get: { editingNote != nil }, set: { if !$0 { editingNote = nil } })
            ) {
                TextField("Room note", text: $noteText)
                Button("Save") {
                    if let room = editingNote { model.setNote(noteText, for: room.uid) }
                    editingNote = nil
                }
                Button("Cancel", role: .cancel) { editingNote = nil }
            } message: {
                Text("Notes mark a room on the map and are searchable with “mapper notes”.")
            }
        }
    }

    @ViewBuilder
    private func pulse(for layout: MapLayout, geometry: MapGeometry) -> some View {
        if let current = layout.rooms.first(where: { $0.uid == layout.current }) {
            let centre = geometry.screen(current.point)
            PulseRing(diameter: geometry.room * 2.4)
                .position(centre)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private func header(_ layout: MapLayout) -> some View {
        if let current = layout.rooms.first(where: { $0.uid == layout.current }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(MapPalette.areaTint(current.areaColor))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let area = current.areaName {
                        Text(area).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if current.isPK { PKBadge(blink: layout.pkBlink) }
                Text(current.uid).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // A soft red ring when standing in a PK room — contained to the
            // map panel, not an app-wide alarm.
            .overlay {
                if current.isPK {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(MapPalette.pk.opacity(0.8), lineWidth: 1.5)
                }
            }
            .padding(8)
        }
    }

    /// Hover info shown in a fixed strip pinned to the bottom edge, so it
    /// never covers the room under the cursor (the v1 floating tooltip did).
    @ViewBuilder
    private var infoBar: some View {
        if let room = hovered {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(room.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(room.uid).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let area = room.areaName { label("Area", area) }
                if !room.exits.isEmpty { label("Exits", room.exits.joined(separator: ", ")) }
                if let terrain = room.terrain, !terrain.isEmpty { label("Terrain", terrain) }
                if let note = room.note, !note.isEmpty { label("Note", note) }
            }
            .padding(8)
            .frame(maxWidth: 230, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 6)
            .padding(8)
            .allowsHitTesting(false)
        }
    }

    private func label(_ key: String, _ value: String) -> some View {
        (Text("\(key): ").foregroundStyle(.secondary) + Text(value))
            .font(.caption2).lineLimit(2)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let room = hovered {
            Text(room.name)
            Button("Walk here") { model.walk(to: room.uid) }
            Button("Go here (portals)") { model.go(to: room.uid) }
            Button("Where") { model.showWhere(room.uid) }
            Divider()
            Button((room.note?.isEmpty == false) ? "Edit Note…" : "Add Note…") { beginEditingNote(room) }
            if room.note?.isEmpty == false {
                Button("Clear Note") { model.setNote("", for: room.uid) }
            }
            Divider()
            Button("Recenter") { recenter() }
        } else {
            Button("Recenter") { recenter() }
            Button("Reset zoom") { zoom = 1; zoomStart = 1 }
        }
    }

    private func beginEditingNote(_ room: PlacedRoom) {
        editingNote = room
        noteText = room.note ?? ""
    }

    private var toolbar: some View {
        VStack(spacing: 1) {
            toolbarButton("plus") { setZoom(zoom * 1.25) }
            Divider().frame(width: 28)
            toolbarButton("minus") { setZoom(zoom / 1.25) }
            Divider().frame(width: 28)
            toolbarButton("scope") { recenter() }
            Divider().frame(width: 28)
            toolbarButton(
                model.showOtherAreas ? "square.on.square" : "square",
                tint: model.showOtherAreas ? .accentColor : nil,
                help: "Show neighbouring areas"
            ) { model.toggleShowOtherAreas() }
            Divider().frame(width: 28)
            toolbarButton(
                "arrow.up.left.and.arrow.down.right",
                tint: model.showAreaExits ? .accentColor : nil,
                help: "Mark exits to other areas"
            ) { model.toggleShowAreaExits() }
            Divider().frame(width: 28)
            toolbarButton("square.and.arrow.down", help: "Import a map database…") {
                model.importDatabase()
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    private func toolbarButton(
        _ symbol: String,
        tint: Color? = nil,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .foregroundStyle(tint ?? .primary)
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }

    // MARK: - Interaction helpers

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { pan = CGSize(
                width: panStart.width + $0.translation.width,
                height: panStart.height + $0.translation.height
            ) }
            .onEnded { _ in panStart = pan }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { setZoom(zoomStart * $0.magnification) }
            .onEnded { _ in zoomStart = zoom }
    }

    private func tapGesture(layout: MapLayout, geometry: MapGeometry) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let room = room(at: value.location, layout: layout, geometry: geometry),
                      room.uid != layout.current else { return }
                model.go(to: room.uid)
            }
    }

    private func room(at point: CGPoint, layout: MapLayout, geometry: MapGeometry) -> PlacedRoom? {
        let half = geometry.room / 2 + 2
        return layout.rooms.first { room in
            let centre = geometry.screen(room.point)
            return abs(point.x - centre.x) <= half && abs(point.y - centre.y) <= half
        }
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 0.4), 3)
        zoomStart = zoom
    }

    private func recenter() {
        pan = .zero
        panStart = .zero
    }
}

/// Grid → screen mapping shared by drawing and hit-testing. The current room
/// (grid origin) sits at the viewport centre plus the pan offset.
struct MapGeometry {
    let size: CGSize
    let zoom: CGFloat
    let pan: CGSize

    // Tight packing matching the Aardwolf mapper's density (it uses 12/8).
    private static let baseRoom: CGFloat = 17
    private static let baseGap: CGFloat = 8

    var room: CGFloat {
        Self.baseRoom * zoom
    }

    var pitch: CGFloat {
        (Self.baseRoom + Self.baseGap) * zoom
    }

    func screen(_ point: GridPoint) -> CGPoint {
        CGPoint(
            x: size.width / 2 + pan.width + CGFloat(point.x) * pitch,
            y: size.height / 2 + pan.height + CGFloat(point.y) * pitch
        )
    }
}

/// A soft glow marking the current room (Mudlet-inspired, restrained). Static by
/// design: a `repeatForever` pulse here kept the whole map redrawing at 60fps
/// while the Map panel was open — a constant, traffic-independent CPU/GPU drain.
private struct PulseRing: View {
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [MapPalette.current.opacity(0.55), MapPalette.current.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .opacity(0.6)
    }
}

/// A gently pulsing "⚔ PK" pill shown in the header when the current room is
/// a player-kill room — the Aardwolf mapper's title-blink warning, reimagined
/// as a contained badge (no app-wide alarm).
private struct PKBadge: View {
    /// When false the badge is shown static (the indicator stays; only the
    /// animation is suppressed — Aardwolf's `BLINK_PK_TITLE` off).
    let blink: Bool
    @State private var on = false

    var body: some View {
        Text("⚔ PK")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(MapPalette.pk, in: Capsule())
            .opacity(blink && !on ? 0.45 : 1.0)
            .animation(
                blink ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: on
            )
            .onAppear { on = true }
            .help("You are in a player-kill room.")
    }
}
