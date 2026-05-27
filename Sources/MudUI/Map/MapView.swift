import MudCore
import SwiftUI

/// The Map window: renders the latest captured ASCII map (Aardwolf's
/// `<MAPSTART>…<MAPEND>` block) as styled monospace lines. Driven by the
/// native ASCII-map plugin via ``MapModel``/``MapStore``.
public struct MapView: View {
    @Bindable private var model: MapModel

    public init(model: MapModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.lines.isEmpty {
                ContentUnavailableView(
                    "No Map Yet",
                    systemImage: "map",
                    description: Text("The area map appears here once you're connected and moving.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Size to the map exactly (the automap is a bounded viewport) so
                // a floating miniwindow hugs it with no scrollbars. A compact
                // monospaced font keeps the HUD small; the box-drawing glyphs of
                // Aardwolf's solid-line map types align in monospace.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.attributedText())
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .fixedSize()
            }
        }
        .task { await model.start() }
    }
}
