import MudCore
import SwiftUI

/// Renders a captured continent bigmap while the player travels overland:
/// each map character becomes a coloured cell (the reference Bigmap plugin
/// draws 8px squares per character), aspect-fit to the panel, with the
/// player's position ringed at the GMCP `coord.x`/`coord.y` cell.
struct ContinentMapView: View {
    let map: BigmapStore.ContinentMap
    let position: MapLayout.Continent
    let palette: ColorPalette

    var body: some View {
        GeometryReader { geo in
            let columns = map.lines.map(\.text.utf16.count).max() ?? 0
            let rows = map.lines.count
            if columns > 0, rows > 0 {
                let cell = min(geo.size.width / CGFloat(columns), geo.size.height / CGFloat(rows))
                let origin = CGPoint(
                    x: (geo.size.width - cell * CGFloat(columns)) / 2,
                    y: (geo.size.height - cell * CGFloat(rows)) / 2
                )
                Canvas { context, _ in
                    drawCells(context: context, cell: cell, origin: origin)
                    drawPlayerMarker(context: context, cell: cell, origin: origin)
                }
            }
        }
        .overlay(alignment: .topLeading) { header }
    }

    /// Continent name + location, like the reference's window dressing.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(map.name).font(.caption.weight(.semibold))
            Text("Location: \(position.x), \(position.y)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    /// One filled rect per non-space character, coloured by its style run.
    private func drawCells(context: GraphicsContext, cell: CGFloat, origin: CGPoint) {
        for (row, line) in map.lines.enumerated() {
            let utf16 = Array(line.text.utf16)
            for (column, unit) in utf16.enumerated() {
                guard let scalar = Unicode.Scalar(unit), scalar != " " else { continue }
                let style = line.runs.first { $0.utf16Range.contains(column) }?.style
                let rgb = palette.resolveForeground(style?.foreground, bold: style?.bold ?? false)
                let rect = CGRect(
                    x: origin.x + CGFloat(column) * cell,
                    y: origin.y + CGFloat(row) * cell,
                    width: cell,
                    height: cell
                )
                context.fill(Path(rect), with: .color(Color(rgb)))
            }
        }
    }

    /// The reference rings the player cell (cornflower/cyan rounded rects
    /// plus a tight cell box); one accent ring + cell box reads the same.
    private func drawPlayerMarker(context: GraphicsContext, cell: CGFloat, origin: CGPoint) {
        let x = origin.x + CGFloat(position.x) * cell
        let y = origin.y + CGFloat(position.y) * cell
        let ring = CGRect(x: x - cell * 2.5, y: y - cell * 2.5, width: cell * 6, height: cell * 6)
        context.stroke(
            Path(roundedRect: ring, cornerRadius: cell * 1.5),
            with: .color(.cyan),
            lineWidth: 2
        )
        let box = CGRect(x: x, y: y, width: cell, height: cell)
        context.stroke(Path(box), with: .color(.cyan), lineWidth: 1.5)
    }
}
