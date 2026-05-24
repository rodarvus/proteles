import MudCore
import SwiftUI

/// The native Search-and-Destroy dock panel — S&D's miniwindow reimagined in
/// SwiftUI, fed by the model S&D's own logic publishes. Render-only for now;
/// the action buttons + click-to-navigate are wired in a later stage.
public struct SearchAndDestroyPanelView: View {
    @Bindable private var model: SnDPanelModel

    public init(model: SnDPanelModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let snd = model.model, snd.activity != nil, snd.activity != "init" {
                content(snd)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state (still offers Scan + Import)

    private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "No Hunt Active",
                systemImage: "scope",
                description: Text(
                    "Start a campaign or quest — targets appear here automatically as "
                        + "Search & Destroy detects it."
                )
            )
            if model.isInteractive {
                Button("Import SnDdb.db…") { model.requestImport() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private func content(_ snd: SearchAndDestroyModel) -> some View {
        VStack(spacing: 0) {
            header(snd)
            Divider()
            toolbar
            Divider()
            List {
                ForEach(snd.targets) { target in
                    targetRow(target)
                        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                        .listRowBackground(target.current ? SnDPalette.currentRow : Color.clear)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Header

    private func header(_ snd: SearchAndDestroyModel) -> some View {
        HStack(spacing: 8) {
            Text(snd.activityLabel.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(SnDPalette.accent)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(SnDPalette.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text("Search & Destroy").font(.subheadline.weight(.semibold))
                Text(remainingSummary(snd)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private func remainingSummary(_ snd: SearchAndDestroyModel) -> String {
        let alive = snd.targets.count(where: { !$0.dead })
        return "\(snd.targets.count) targets · \(alive) left"
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            // The original miniwindow's action buttons → S&D aliases.
            commandButton(
                "⚔ xcp",
                command: "xcp",
                prominent: true,
                help: "Get the current campaign/quest target"
            )
            commandButton("Next →", command: "nx", help: "Go to the next target")
            commandButton("Refresh", command: "xgui ref", help: "Refresh the target list")
            Spacer()
            gearMenu
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(SnDPalette.toolbar)
    }

    private func commandButton(
        _ label: String,
        command: String,
        prominent: Bool = false,
        help: String
    ) -> some View {
        Button { model.run(command) } label: {
            buttonLabel(label, prominent: prominent)
        }
        .buttonStyle(.plain)
        .disabled(!model.isInteractive)
        .help(help)
    }

    private var gearMenu: some View {
        Menu {
            Button("Go to Room 1") { model.run("go") }
            Button("Quick-Scan") { model.run("qs") }
            Button("Hunt Trick") { model.run("ht") }
            Divider()
            Button("Re-check Campaign/Quest") { model.scan() }
            Button("Import SnDdb.db…") { model.requestImport() }
        } label: {
            buttonLabel("⚙︎")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.isInteractive)
        .help("More actions")
    }

    private func buttonLabel(_ label: String, prominent: Bool = false) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .primary)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(
                prominent ? SnDPalette.accent : SnDPalette.button,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    // MARK: - Target row

    /// A target row, clickable when interactive — a click re-targets it via
    /// `xcp <index>` (the original miniwindow's clickable-link behaviour).
    @ViewBuilder
    private func targetRow(_ target: SearchAndDestroyModel.Target) -> some View {
        if model.isInteractive {
            Button { model.selectTarget(target.index) } label: {
                row(target)
            }
            .buttonStyle(.plain)
            .help("Go to target \(target.index)")
        } else {
            row(target)
        }
    }

    private func row(_ target: SearchAndDestroyModel.Target) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(target.index))")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            if let dups = target.duplicates, dups > 1, let which = target.dupIndex {
                Text("(\(which)/\(dups))").font(.caption2).foregroundStyle(.secondary)
            }
            if let qty = target.qty, qty > 0 {
                Text("\(qty)×").font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(SnDPalette.express)
            }
            if target.unlikely { tag("UNLIKELY", color: SnDPalette.unlikely) }
            if target.express { tag("EXPRESS", color: SnDPalette.express, filled: true) }
            Text(target.mob ?? "?")
                .font(.callout.weight(.semibold))
                .strikethrough(target.dead)
                .foregroundStyle(target.dead ? SnDPalette.dead : .primary)
            Text(locationText(target))
                .font(.caption).foregroundStyle(target.dead ? SnDPalette.dead : .secondary)
                .lineLimit(1)
            if target.dead { tag("DEAD", color: SnDPalette.dead) }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func locationText(_ target: SearchAndDestroyModel.Target) -> String {
        switch target.linkType {
        case "room": "— '\(target.room ?? "?")' (\(target.area ?? "?"))"
        case "unknown": "— '\(target.location ?? "?")' (unknown)"
        default: "— \(target.area ?? target.location ?? "?")"
        }
    }

    private func tag(_ text: String, color: Color, filled: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(filled ? Color.black.opacity(0.85) : color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(filled ? color.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Palette for the S&D panel (S&D's accent orange + status colours).
enum SnDPalette {
    static let accent = Color(red: 1.0, green: 0.31, blue: 0.0)
    static let express = Color(red: 0.96, green: 0.80, blue: 0.30)
    static let unlikely = Color(red: 0.44, green: 0.44, blue: 0.46)
    static let dead = Color(red: 0.42, green: 0.42, blue: 0.46)
    static let currentRow = Color(red: 1.0, green: 0.18, blue: 0.57).opacity(0.14)
    static let toolbar = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let button = Color(red: 0.11, green: 0.11, blue: 0.13)
}
