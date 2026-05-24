import MudCore
import SwiftUI

/// Canvas drawing helpers for the graphical map (split out of
/// MapPanelView to keep its body within the type-length budget).
extension MapPanelView {
    func draw(_ link: MapLink, in context: GraphicsContext, geometry: MapGeometry) {
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

    func drawArrowhead(
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

    func draw(_ room: PlacedRoom, in context: GraphicsContext, geometry: MapGeometry) {
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

    /// Draw an area-exit boundary marker: a thick gold bar across the room's
    /// edge in the exit direction, with the destination area's name beside it.
    func draw(_ marker: AreaExitMarker, in context: GraphicsContext, geometry: MapGeometry) {
        guard let delta = MapLayout.gridDelta[marker.dir] else { return }
        let centre = geometry.screen(marker.from)
        let half = geometry.room / 2
        let mag = max(
            (CGFloat(delta.x) * CGFloat(delta.x) + CGFloat(delta.y) * CGFloat(delta.y)).squareRoot(),
            0.0001
        )
        let outX = CGFloat(delta.x) / mag
        let outY = CGFloat(delta.y) / mag
        // Bar centred just outside the room edge, perpendicular to the exit.
        let edge = CGPoint(x: centre.x + outX * (half + 2), y: centre.y + outY * (half + 2))
        let halfBar = half * 0.9
        var bar = Path()
        bar.move(to: CGPoint(x: edge.x - outY * halfBar, y: edge.y + outX * halfBar))
        bar.addLine(to: CGPoint(x: edge.x + outY * halfBar, y: edge.y - outX * halfBar))
        context.stroke(
            bar,
            with: .color(MapPalette.areaExit),
            style: StrokeStyle(lineWidth: 3, lineCap: .round)
        )

        let labelPoint = CGPoint(x: centre.x + outX * (half + 11), y: centre.y + outY * (half + 11))
        let text = Text(marker.area).font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(MapPalette.areaExit)
        context.draw(text, at: labelPoint)
    }

    /// Fill a room with thin diagonal hatch lines (used for unvisited rooms),
    /// clipped to the room's rounded shape.
    func drawHatch(in rect: CGRect, clip: Path, colour: Color, context: GraphicsContext) {
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

    func chevron(up: Bool, in rect: CGRect, colour: Color, context: GraphicsContext) {
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
}
