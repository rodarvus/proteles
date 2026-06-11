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
            if let snd = model.model, hasContent(snd) {
                content(snd)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Show the live panel when there's anything to surface — an activity, a
    /// quest target, a requestable quest, or campaign/global targets. Otherwise
    /// the empty/idle state. (`activity == "init"` alone — fresh load before any
    /// detection — is *not* content, but a can-request quest published in that
    /// state still is, which is why we don't gate purely on `activity`.)
    private func hasContent(_ snd: SearchAndDestroyModel) -> Bool {
        (snd.activity != nil && snd.activity != "init")
            || snd.quest != nil
            || snd.canRequestQuest
            || !snd.targets.isEmpty
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if model.isInstalled {
            noHuntState
        } else {
            notInstalledState
        }
    }

    private var noHuntState: some View {
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

    /// S&D isn't part of Proteles — offer to download + install it on request.
    private var notInstalledState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "Search & Destroy Not Installed",
                systemImage: "arrow.down.circle",
                description: Text(
                    "Search & Destroy is a third-party Aardwolf plugin by Crowley — not part of "
                        + "Proteles. Install it to track campaign and quest targets here."
                )
            )
            if model.isInstalling {
                ProgressView("Installing…").controlSize(.small)
            } else if model.isInteractive {
                Button("Install Search & Destroy…") { model.requestInstall() }
                    .buttonStyle(.borderedProminent)
            }
            if let error = model.installError {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private func content(_ snd: SearchAndDestroyModel) -> some View {
        VStack(spacing: 0) {
            header(snd)
            Divider()
            // When on a quest, the quest shows first — a distinct banner with a
            // small separator above the campaign/global targets.
            if let quest = snd.quest, quest.status == "2" || quest.status == "3" {
                questBanner(quest)
                Divider()
            }
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

    // MARK: - Quest banner

    /// The open quest, shown above the campaign targets. While the target's
    /// alive (qstat 2) the row click runs straight to it via S&D's `go` (walks
    /// `gotoList[1]` — the quest mob's room — cross-area through the mapper; S&D
    /// builds that list on quest-request, so a single `go` gets you all the way,
    /// no manual step). When killed (qstat 3) the banner turns green and is
    /// informational: return to the questor to complete.
    private func questBanner(_ quest: SearchAndDestroyModel.Quest) -> some View {
        let canNavigate = model.isInteractive && quest.status == "2"
        return Button {
            if canNavigate { model.run("go") }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: quest.killed ? "checkmark.seal.fill" : "flag.checkered")
                    .font(.caption)
                    .foregroundStyle(quest.killed ? SnDPalette.complete : SnDPalette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(quest.mob ?? "Quest target")
                        .font(.callout.weight(.semibold))
                    Text(quest.killed ? "Target killed — return to the questor" : questLocation(quest))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if quest.killed { tag("RETURN TO QUESTOR", color: SnDPalette.complete, filled: true) }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canNavigate)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background((quest.killed ? SnDPalette.complete : SnDPalette.accent)
            .opacity(quest.killed ? 0.18 : 0.08))
    }

    private func questLocation(_ quest: SearchAndDestroyModel.Quest) -> String {
        let area = quest.areaName ?? quest.area
        return switch (quest.room, area) {
        case (let room?, let area?): "Quest · '\(room)' (\(area))"
        case (let room?, nil): "Quest · '\(room)'"
        case (nil, let area?): "Quest · \(area)"
        default: "Quest target"
        }
    }

    // MARK: - Header

    private func header(_ snd: SearchAndDestroyModel) -> some View {
        HStack(spacing: 8) {
            Text(activityBadge(snd))
                .font(.caption2.weight(.bold))
                .foregroundStyle(SnDPalette.accent)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(SnDPalette.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text("Search & Destroy").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(remainingSummary(snd)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(-1)
            // Actions sit right of the campaign label (was a separate toolbar
            // row — folded in here to save vertical space).
            actions
            Spacer()
            // Off-quest: either a new quest can be requested now (qstat 0), or
            // we're on cooldown (qstat 1) → show the remaining wait.
            if snd.canRequestQuest {
                tag("QUEST READY", color: SnDPalette.express, filled: true)
            } else if let cooldown = questCooldown(snd) {
                questCooldownBadge(cooldown)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    /// The off-quest cooldown's next-requestable time when waiting (qstat 1) and
    /// it's still in the future; `nil` otherwise.
    private func questCooldown(_ snd: SearchAndDestroyModel) -> Double? {
        guard snd.quest?.status == "1", let next = snd.nextQuestTime,
              next > Date().timeIntervalSince1970 else { return nil }
        return next
    }

    /// The off-quest cooldown badge — a live-updating "Quest in N min" from the
    /// next-requestable time. A 30 s `TimelineView` (the tick-readout pattern)
    /// re-derives the label, NOT `Text(_, style: .relative)`: relative text
    /// keeps SwiftUI's time-formatting machinery resolving continuously, which
    /// showed up in the #61 main-thread samples whenever this panel was open.
    private func questCooldownBadge(_ unixTime: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "hourglass")
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let remaining = unixTime - context.date.timeIntervalSince1970
                let minutes = Swift.max(0, Int((remaining / 60).rounded(.up)))
                Text(minutes > 0 ? "Quest in \(minutes)m" : "Quest soon")
            }
        }
        .font(.system(size: 9, weight: .bold))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(SnDPalette.unlikely)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(SnDPalette.unlikely.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    /// The activity badge — appends the global-quest id when on a GQ.
    private func activityBadge(_ snd: SearchAndDestroyModel) -> String {
        let label = snd.activityLabel.uppercased()
        if let gqId = snd.gqId, !gqId.isEmpty, gqId != "-1" { return "\(label) #\(gqId)" }
        return label
    }

    private func remainingSummary(_ snd: SearchAndDestroyModel) -> String {
        if snd.targets.isEmpty {
            if let quest = snd.quest, quest.status == "2" || quest.status == "3" { return "On quest" }
            if snd.canRequestQuest { return "Quest available" }
            return "No active targets"
        }
        let alive = snd.targets.count(where: { !$0.dead })
        return "\(snd.targets.count) targets · \(alive) left"
    }

    // MARK: - Actions

    /// The original miniwindow's action buttons (→ S&D aliases), now inline in
    /// the header.
    private var actions: some View {
        HStack(spacing: 6) {
            commandButton(
                "⚔ xcp",
                command: "xcp",
                prominent: true,
                help: "Get the current campaign/quest target"
            )
            commandButton("Next →", command: "nx", help: "Go to the next target")
            commandButton("Refresh", command: "xgui ref", help: "Refresh the target list")
            gearMenu
        }
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
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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
    static let button = Color(red: 0.11, green: 0.11, blue: 0.13)
    /// Quest-complete green — target killed, return to the questor.
    static let complete = Color(red: 0.30, green: 0.78, blue: 0.45)
}
