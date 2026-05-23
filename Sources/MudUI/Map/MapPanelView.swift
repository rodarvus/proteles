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

    public init(model: MapPanelModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.layout.isEmpty {
                ContentUnavailableView(
                    "No Map Yet",
                    systemImage: "map",
                    description: Text("The map appears here once you're connected and moving.")
                )
            } else {
                mapBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.start() }
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
        }
    }

    // MARK: - Drawing

    private func draw(_ link: MapLink, in context: GraphicsContext, geometry: MapGeometry) {
        guard let delta = MapLayout.gridDelta[link.dir] else { return }
        let start = geometry.screen(link.from)
        let length = geometry.pitch * (link.isStub ? 0.42 : 1)
        let unit = CGVector(dx: CGFloat(delta.x), dy: CGFloat(delta.y))
        let mag = max((unit.dx * unit.dx + unit.dy * unit.dy).squareRoot(), 0.0001)
        let end = CGPoint(x: start.x + unit.dx / mag * length, y: start.y + unit.dy / mag * length)

        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        let colour = link.isUpDown ? MapPalette
            .exitUpDown : (link.isLocked ? MapPalette.locked : MapPalette.exit)
        let style = StrokeStyle(
            lineWidth: link.isLocked ? 2.5 : 1.5,
            lineCap: .round,
            dash: link.isUnknownDestination ? [2, 3] : []
        )
        context.stroke(path, with: .color(colour), style: style)

        if link.isOneWay { drawArrowhead(at: end, unit: unit, mag: mag, colour: colour, in: context) }
    }

    private func drawArrowhead(
        at tip: CGPoint, unit: CGVector, mag: CGFloat, colour: Color, in context: GraphicsContext
    ) {
        let dirX = unit.dx / mag
        let dirY = unit.dy / mag
        let size: CGFloat = 5
        let back = CGPoint(x: tip.x - dirX * size, y: tip.y - dirY * size)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: back.x - dirY * size * 0.6, y: back.y + dirX * size * 0.6))
        head.addLine(to: CGPoint(x: back.x + dirY * size * 0.6, y: back.y - dirX * size * 0.6))
        head.closeSubpath()
        context.fill(head, with: .color(colour))
    }

    private func draw(_ room: PlacedRoom, in context: GraphicsContext, geometry: MapGeometry) {
        let centre = geometry.screen(room.point)
        let side = geometry.room
        let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        let shape = Path(roundedRect: rect, cornerRadius: side * 0.28)

        let style = MapPalette.style(for: room)
        if room.kind == .unknown {
            // Unvisited: dark-red fill + diagonal hatch + dotted border.
            context.fill(shape, with: .color(MapPalette.unknownFill))
            drawHatch(in: rect, clip: shape, colour: MapPalette.unknownBorder.opacity(0.7), context: context)
            context.stroke(
                shape,
                with: .color(MapPalette.unknownBorder),
                style: StrokeStyle(lineWidth: 1, dash: [2, 2])
            )
        } else {
            context.fill(shape, with: .color(style.fill))
            context.stroke(shape, with: .color(style.border), lineWidth: style.borderWidth)
        }

        // Note badge (top-left), up chevron (top-right), down chevron (bottom-left).
        if room.hasNote {
            let dot = CGRect(x: rect.minX - 1, y: rect.minY - 1, width: 5, height: 5)
            context.fill(Path(ellipseIn: dot), with: .color(MapPalette.note))
        }
        if room.hasUp { chevron(up: true, in: rect, colour: MapPalette.exitUpDown, context: context) }
        if room.hasDown { chevron(up: false, in: rect, colour: MapPalette.exitUpDown, context: context) }

        // PK danger pip (top-right), unless that corner is busy with an up chevron.
        if room.isPK, !room.hasUp {
            let pip = CGRect(x: rect.maxX - 4, y: rect.minY, width: 4, height: 4)
            context.fill(Path(pip), with: .color(MapPalette.pk))
        }

        if side >= 13, let glyph = style.glyph {
            let text = Text(glyph).font(.system(size: side * 0.62, weight: .bold))
                .foregroundColor(style.glyphColour)
            context.draw(text, at: centre)
        }
    }

    /// Fill a room with thin diagonal hatch lines (used for unvisited rooms),
    /// clipped to the room's rounded shape.
    private func drawHatch(in rect: CGRect, clip: Path, colour: Color, context: GraphicsContext) {
        var inner = context
        inner.clip(to: clip)
        var path = Path()
        var offset = -rect.height
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += 4
        }
        inner.stroke(path, with: .color(colour), lineWidth: 1)
    }

    private func chevron(up: Bool, in rect: CGRect, colour: Color, context: GraphicsContext) {
        let size: CGFloat = 4
        var path = Path()
        if up {
            let apex = CGPoint(x: rect.maxX - size, y: rect.minY - size)
            path.move(to: apex)
            path.addLine(to: CGPoint(x: apex.x - size, y: apex.y + size))
            path.addLine(to: CGPoint(x: apex.x + size, y: apex.y + size))
        } else {
            let apex = CGPoint(x: rect.minX + size, y: rect.maxY + size)
            path.move(to: apex)
            path.addLine(to: CGPoint(x: apex.x - size, y: apex.y - size))
            path.addLine(to: CGPoint(x: apex.x + size, y: apex.y - size))
        }
        path.closeSubpath()
        context.fill(path, with: .color(colour))
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
                if current.isPK { PKBadge() }
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
            Button("Recenter") { recenter() }
        } else {
            Button("Recenter") { recenter() }
            Button("Reset zoom") { zoom = 1; zoomStart = 1 }
        }
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

/// A softly pulsing ring marking the current room (Mudlet-inspired, restrained).
private struct PulseRing: View {
    let diameter: CGFloat
    @State private var on = false

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
            .scaleEffect(on ? 1.0 : 0.7)
            .opacity(on ? 0.25 : 0.7)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// A gently pulsing "⚔ PK" pill shown in the header when the current room is
/// a player-kill room — the Aardwolf mapper's title-blink warning, reimagined
/// as a contained badge (no app-wide alarm).
private struct PKBadge: View {
    @State private var on = false

    var body: some View {
        Text("⚔ PK")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(MapPalette.pk, in: Capsule())
            .opacity(on ? 1.0 : 0.45)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .help("You are in a player-kill room.")
    }
}
