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
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.attributedText())
                                .font(.system(.body, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.start() }
    }
}
