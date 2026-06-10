import SwiftUI

/// Icon picker for a command button (D-106): a popover grid of curated,
/// game-relevant SF Symbols — replacing the typo-prone bare name field as
/// the primary path — plus a free-text field for any other symbol name.
struct ButtonSymbolPicker: View {
    /// The button's `icon` (an SF Symbol name); nil/empty = no icon.
    @Binding var symbol: String?
    @State private var showingGrid = false

    /// Hand-picked for MUD play: combat, healing, navigation, loot, timing,
    /// comms, state. All verified SF Symbol names.
    private static let curated: [String] = [
        "bolt.fill", "flame.fill", "shield.fill", "shield.lefthalf.filled",
        "scope", "target", "burst.fill", "exclamationmark.triangle.fill",
        "heart.fill", "cross.case.fill", "bandage.fill", "pills.fill",
        "drop.fill", "leaf.fill", "zzz", "sparkles",
        "wand.and.stars", "eye.fill", "moon.fill", "sun.max.fill",
        "map.fill", "location.fill", "figure.walk", "arrow.triangle.2.circlepath",
        "bag.fill", "dollarsign.circle.fill", "key.fill", "lock.fill",
        "book.fill", "scroll.fill", "bell.fill", "bubble.left.fill",
        "hourglass", "timer", "play.fill", "stop.fill"
    ]

    var body: some View {
        LabeledContent("Icon") {
            HStack(spacing: 8) {
                if let symbol, !symbol.isEmpty {
                    ButtonIconView(icon: symbol)
                        .frame(minWidth: 20)
                }
                Button(symbol?.isEmpty == false ? "Change…" : "Choose…") {
                    showingGrid = true
                }
                .popover(isPresented: $showingGrid, arrowEdge: .bottom) {
                    grid
                }
                if symbol?.isEmpty == false {
                    Button("Remove") { symbol = nil }
                }
            }
        }
        TextField("Or any SF Symbol name — or an emoji", text: Binding(
            get: { symbol ?? "" },
            set: { symbol = $0.isEmpty ? nil : $0 }
        ))
        .autocorrectionDisabled()
        .font(.body.monospaced())
    }

    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 6),
            spacing: 6
        ) {
            ForEach(Self.curated, id: \.self) { name in
                Button {
                    symbol = name
                    showingGrid = false
                } label: {
                    Image(systemName: name)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .background(
                            symbol == name ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(name)
            }
        }
        .padding(10)
    }
}
