import MudCore
import SwiftUI

/// The floating Consider panel: the room's mobs numbered and coloured by
/// difficulty tier, each a click-to-attack row, with a header carrying the
/// default command, auto-refresh toggle, refresh, batch sweep, and execute mode.
/// Renders the latest ``ConsiderPanelModel/snapshot``.
public struct ConsiderPanelView: View {
    @Bindable var model: ConsiderPanelModel

    public init(model: ConsiderPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Divider()
            if let note = model.snapshot.statusNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else if model.snapshot.mobs.isEmpty {
                Text("No mobs here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                mobList
            }
        }
        .padding(8)
        .frame(minWidth: 200, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Consider")
                .font(.headline)
            Text("(\(model.snapshot.defaultCommand))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh now (consider all)")
            Button { model.attackAll() } label: { Image(systemName: "flame") }
                .help("Attack all matching mobs (conwall)")
            Button { model.toggleEnabled() } label: {
                Image(systemName: model.snapshot.enabled ? "bolt.fill" : "bolt.slash")
            }
            .help(model.snapshot.enabled ? "Auto-refresh on" : "Auto-refresh off")
        }
        .buttonStyle(.borderless)
        .disabled(!model.isInteractive)
    }

    private var mobList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.snapshot.mobs.enumerated()), id: \.element.id) { offset, mob in
                MobRow(position: offset + 1, mob: mob) { model.attack(offset + 1) }
                    .disabled(!model.isInteractive || mob.dead || mob.left)
            }
        }
    }
}

/// One clickable mob row: `N. (flags) name (range)`, coloured by tier, struck
/// through when dead/left, bold once attacked.
private struct MobRow: View {
    let position: Int
    let mob: ConsiderMob
    let onAttack: () -> Void

    var body: some View {
        Button(action: onAttack) {
            HStack(spacing: 4) {
                Text("\(position).")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ForEach(ConsiderColour.auraFlags(mob.rawFlags)) { flag in
                    Text(flag.id)
                        .foregroundStyle(flag.color)
                }
                Text(mob.name)
                    .foregroundStyle(ConsiderColour.color(for: mob.colour))
                    .fontWeight(mob.attacked ? .bold : .regular)
                    .strikethrough(mob.dead || mob.left)
                if !mob.rangeLabel.isEmpty {
                    Text("(\(mob.rangeLabel))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Attack \(mob.index).\(mob.keyword)")
    }
}

/// Maps the plugin's CSS-style tier colour names to concrete colours, tuned
/// slightly for legibility on dark chrome.
enum ConsiderColour {
    private static let palette: [String: Color] = [
        "gray": rgb(128, 128, 128),
        "darkgreen": rgb(0, 128, 0),
        "forestgreen": rgb(34, 139, 34),
        "chartreuse": rgb(127, 205, 0),
        "springgreen": rgb(0, 200, 120),
        "darkgoldenrod": rgb(184, 134, 11),
        "gold": rgb(212, 175, 0),
        "tomato": rgb(255, 99, 71),
        "crimson": rgb(220, 20, 60),
        "lightpink": rgb(235, 145, 160),
        "darkmagenta": rgb(170, 0, 170),
        "darkviolet": rgb(148, 0, 211),
        "magenta": rgb(230, 0, 230)
    ]

    static func color(for name: String) -> Color {
        palette[name] ?? .primary
    }

    /// A coloured aura badge shown before a mob's name.
    struct AuraFlag: Identifiable {
        let id: String
        let color: Color
    }

    /// The aura flags present in a mob's captured prefix, coloured like the
    /// original plugin's `Process_flags`: white aura `(W)`, red aura `(R)` =
    /// evil, golden aura `(G)` = good. Accepts the abbreviated `(R)` or the full
    /// `(Red Aura)` form. `(W)` stacks with `(R)`/`(G)`.
    static func auraFlags(_ raw: String) -> [AuraFlag] {
        let lower = raw.lowercased()
        var flags: [AuraFlag] = []
        if lower.contains("(w)") || lower.contains("white aura") {
            flags.append(AuraFlag(id: "(W)", color: rgb(230, 230, 230)))
        }
        if lower.contains("(r)") || lower.contains("red aura") {
            flags.append(AuraFlag(id: "(R)", color: rgb(220, 60, 60)))
        } else if lower.contains("(g)") || lower.contains("golden aura") {
            flags.append(AuraFlag(id: "(G)", color: rgb(212, 175, 0)))
        }
        return flags
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }
}
