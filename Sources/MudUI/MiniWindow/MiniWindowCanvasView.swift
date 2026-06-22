import MudCore
import SwiftUI

/// Replays a ``MiniWindowScene``'s retained draw-command list with a SwiftUI
/// `Canvas` — the rendering half of the miniwindow spike. Modeled on
/// `MapPanelView+Drawing` (the existing `GraphicsContext` precedent).
///
/// Coordinates are MUSHclient pixels (top-left origin); a right/bottom `<= 0`
/// resolves relative to the window edge (``MiniWindowScene/fix(_:extent:)``).
/// Rendering through `Canvas` is what makes these "nicer than MUSHclient" for
/// free — antialiased shapes, crisp CoreText glyphs — while keeping the 1:1
/// pixel geometry the plugin's own layout math depends on.
struct MiniWindowCanvasView: View {
    let scene: MiniWindowScene
    /// Resolve a decoded image for an `imageID` (Phase 3); `nil` until loaded.
    var imageProvider: (String) -> CGImage? = { _ in nil }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            for command in scene.commands {
                draw(command, in: context)
            }
        }
        .frame(width: CGFloat(scene.width), height: CGFloat(scene.height))
    }

    // MARK: - Command replay

    private func draw(_ command: MiniWindowCommand, in context: GraphicsContext) {
        switch command {
        case .rect(let action, let left, let top, let right, let bottom, let colour1, let colour2):
            drawRect(action, rect(left, top, right, bottom), colour1, colour2, in: context)
        case .text(let fontID, let text, let left, let top, let right, let bottom, let colour):
            drawText(fontID, text, rect(left, top, right, bottom), colour, in: context)
        case .line(let x1, let y1, let x2, let y2, let colour, let penStyle, let penWidth):
            let pen = Pen(colour: colour, style: penStyle, width: penWidth)
            drawLine(CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2), pen, in: context)
        case .setPixel(let x, let y, let colour):
            if let fill = color(colour) {
                context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(fill))
            }
        case .gradient(let left, let top, let right, let bottom, let start, let end, let mode):
            drawGradient(rect(left, top, right, bottom), start, end, mode, in: context)
        default:
            drawShape(command, in: context)
        }
    }

    private func drawShape(_ command: MiniWindowCommand, in context: GraphicsContext) {
        switch command {
        case .circle(
            let action,
            let left,
            let top,
            let right,
            let bottom,
            let pen,
            let penStyle,
            let penWidth,
            let brush,
            _,
            let extra1,
            let extra2
        ):
            let path = circlePath(
                action,
                rect(left, top, right, bottom),
                corner: CGSize(width: extra1 / 2, height: extra2 / 2)
            )
            fillStroke(path, Pen(colour: pen, style: penStyle, width: penWidth), brush, in: context)
        case .polygon(let points, let pen, let penStyle, let penWidth, let brush, _, let close, _):
            fillStroke(
                polygonPath(points, close: close),
                Pen(colour: pen, style: penStyle, width: penWidth),
                brush,
                in: context
            )
        case .arc(
            let left,
            let top,
            let right,
            let bottom,
            _,
            _,
            _,
            _,
            let colour,
            let penStyle,
            let penWidth
        ):
            fillStroke(
                Path(ellipseIn: rect(left, top, right, bottom)),
                Pen(colour: colour, style: penStyle, width: penWidth),
                -1,
                in: context
            )
        case .bezier(let points, let colour, let penStyle, let penWidth):
            fillStroke(
                bezierPath(points),
                Pen(colour: colour, style: penStyle, width: penWidth),
                -1,
                in: context
            )
        case .image(let imageID, let left, let top, let right, let bottom, _, let opacity, _, _, _, _):
            drawImage(imageID, rect(left, top, right, bottom), opacity, in: context)
        default:
            break
        }
    }

    /// Fill `path` with `brush` (if a colour) then stroke its outline with `pen`
    /// — the shared body for circle/polygon/arc/bezier. `brush == -1` skips fill.
    private func fillStroke(_ path: Path, _ pen: Pen, _ brush: Int, in context: GraphicsContext) {
        if let fill = color(brush) { context.fill(path, with: .color(fill)) }
        if let stroke = color(pen.colour) {
            context.stroke(path, with: .color(stroke), style: strokeStyle(pen))
        }
    }

    private func circlePath(_ action: Int, _ rect: CGRect, corner: CGSize) -> Path {
        switch action {
        case 2: Path(rect) // rectangle
        case 3: Path(roundedRect: rect, cornerSize: corner) // round-rect
        default: Path(ellipseIn: rect) // ellipse / chord / pie (approx)
        }
    }

    private func polygonPath(_ points: [MWPoint], close: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        if close { path.closeSubpath() }
        return path
    }

    private func bezierPath(_ points: [MWPoint]) -> Path {
        var path = Path()
        guard points.count >= 4 else { return path }
        path.move(to: CGPoint(x: points[0].x, y: points[0].y))
        var index = 1
        while index + 2 <= points.count - 1 {
            path.addCurve(
                to: CGPoint(x: points[index + 2].x, y: points[index + 2].y),
                control1: CGPoint(x: points[index].x, y: points[index].y),
                control2: CGPoint(x: points[index + 1].x, y: points[index + 1].y)
            )
            index += 3
        }
        return path
    }

    private func drawRect(
        _ action: Int,
        _ rect: CGRect,
        _ colour1: Int,
        _ colour2: Int,
        in context: GraphicsContext
    ) {
        switch action {
        case 1: // frame
            // MUSHclient's FrameRect draws the 1px border INSIDE the rect (right/
            // bottom edges exclusive → border at right-1 / bottom-1). A stroke
            // centred on the path edge straddles the canvas boundary and clips the
            // right + bottom lines; inset by 0.5px so the whole border sits inside.
            if let stroke = color(colour1) {
                context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(stroke), lineWidth: 1)
            }
        case 3: // invert — approximate with a translucent overlay
            context.fill(Path(rect), with: .color(.white.opacity(0.5)))
        case 4, 5: // 3-D rect / draw-edge — approximate: fill colour1, edge colour2
            if let fill = color(colour1) { context.fill(Path(rect), with: .color(fill)) }
            if let edge = color(colour2) { context.stroke(Path(rect), with: .color(edge), lineWidth: 1) }
        default: // 2 fill, 6/7 flood-fill
            if let fill = color(colour1) { context.fill(Path(rect), with: .color(fill)) }
        }
    }

    private func drawText(
        _ fontID: String, _ text: String, _ clip: CGRect, _ colour: Int, in context: GraphicsContext
    ) {
        guard !text.isEmpty else { return }
        var resolved = context
        // Clip to the text rectangle when one is given, matching MUSHclient's
        // ETO_CLIPPED.
        if clip.width > 0, clip.height > 0 { resolved.clip(to: Path(clip)) }
        let styled = Text(text)
            .font(font(fontID))
            .foregroundStyle(color(colour) ?? .primary)
        resolved.draw(styled, at: CGPoint(x: clip.minX, y: clip.minY), anchor: .topLeading)
    }

    private func drawLine(_ from: CGPoint, _ to: CGPoint, _ pen: Pen, in context: GraphicsContext) {
        guard let stroke = color(pen.colour) else { return }
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(stroke), style: strokeStyle(pen))
    }

    private func drawGradient(
        _ rect: CGRect,
        _ start: Int,
        _ end: Int,
        _ mode: Int,
        in context: GraphicsContext
    ) {
        guard let first = color(start), let second = color(end) else { return }
        let vertical = mode == 2
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [first, second]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY),
            endPoint: vertical ? CGPoint(x: rect.minX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.minY)
        ))
    }

    private func drawImage(
        _ imageID: String,
        _ requested: CGRect,
        _ opacity: Double,
        in context: GraphicsContext
    ) {
        guard let cgImage = imageProvider(imageID) else { return }
        let image = Image(decorative: cgImage, scale: 1)
        let target = (requested.width > 0 && requested.height > 0)
            ? requested
            : CGRect(
                x: requested.minX,
                y: requested.minY,
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            )
        var resolved = context
        resolved.opacity = opacity
        resolved.draw(image, in: target)
    }

    // MARK: - Helpers

    /// A MUSHclient pen (colour + style + width), bundled to keep draw helpers
    /// within the parameter-count budget.
    private struct Pen {
        let colour: Int
        let style: Int
        let width: Int
    }

    /// Resolve a draw rect, applying MUSHclient's FixRight/FixBottom to the
    /// right/bottom coordinates.
    private func rect(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int) -> CGRect {
        let originX = CGFloat(left)
        let originY = CGFloat(top)
        let maxX = MiniWindowScene.fix(right, extent: scene.width)
        let maxY = MiniWindowScene.fix(bottom, extent: scene.height)
        return CGRect(x: originX, y: originY, width: max(0, maxX - originX), height: max(0, maxY - originY))
    }

    private func color(_ bgr: Int) -> Color? {
        guard let parts = MiniWindowColour.components(bgr) else { return nil }
        return Color(red: parts.red, green: parts.green, blue: parts.blue)
    }

    private func font(_ id: String) -> Font {
        guard let descriptor = scene.fonts[id] else { return .system(size: 10, design: .monospaced) }
        var font = Font.custom(
            descriptor.name,
            fixedSize: CGFloat(descriptor.size > 0 ? descriptor.size : 10)
        )
        if descriptor.bold { font = font.weight(.bold) }
        if descriptor.italic { font = font.italic() }
        return font
    }

    /// MUSHclient pen style → SwiftUI stroke (dash patterns for dash/dot).
    private func strokeStyle(_ pen: Pen) -> StrokeStyle {
        let width = CGFloat(max(1, pen.width))
        let dash: [CGFloat] = switch pen.style & 0x0F {
        case 1: [6, 4] // dash
        case 2: [1, 3] // dot
        case 3: [6, 3, 1, 3] // dash-dot
        case 4: [6, 3, 1, 3, 1, 3] // dash-dot-dot
        default: []
        }
        return StrokeStyle(lineWidth: width, dash: dash)
    }
}
