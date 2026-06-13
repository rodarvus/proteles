import MudCore
import SwiftUI

/// The **Levels** dock panel: native reporting over the leveldb plugin's data
/// (DECISIONS.md D-71). A mode picker switches between the live HUD, the faithful
/// tables, the analytics charts, and the journey — all fed by one read-only
/// ``LevelDBPanelModel``. Read-only: the leveldb plugin remains the sole writer.
public struct LevelDBPanelView: View {
    @Bindable private var model: LevelDBPanelModel

    public init(model: LevelDBPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 340, minHeight: 260)
        // Fresh data every time the window opens — the old empty-only guard
        // froze the panel on its connect-time snapshot (live report) — and a
        // gentle auto-refresh while it stays open, so a running grind's
        // levels/pups appear without touching the reload button. Reads are
        // read-only + off-main; the plugin stays the sole writer (D-71).
        .task { model.reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                model.reload()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.databaseMissing {
            placeholder(
                icon: "tray",
                title: "No leveling data yet",
                message: "Connect and play with the leveldb plugin enabled — your kills, "
                    + "quests, and campaigns will appear here."
            )
        } else if let error = model.loadError, model.report.summary.totalKills == 0 {
            placeholder(icon: "exclamationmark.triangle", title: "Couldn't read the database", message: error)
        } else {
            // Days/Insights/Records manage their own scrolling (split view /
            // ScrollView inside); the classic faces keep the shared wrapper.
            switch model.mode {
            case .days:
                LevelDBDaysView(model: model)
                footer
            case .insights:
                LevelDBInsightsView(insights: model.insights)
                footer
            case .records:
                LevelDBRecordsView(records: model.insights.records)
                footer
            case .live, .journey, .tables:
                ScrollView {
                    Group {
                        switch model.mode {
                        case .live: LevelDBLiveView(report: model.report)
                        case .tables: LevelDBReportsView(model: model)
                        case .journey: LevelDBJourneyView(report: model.report)
                        default: EmptyView()
                        }
                    }
                    .padding(14)
                }
                footer
            }
        }
    }

    // MARK: - Header (mode picker + band filter + refresh)

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.mode) {
                ForEach(LevelDBPanelModel.Mode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 4)

            bandMenu

            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload from the database")
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bandMenu: some View {
        Menu {
            Button("All progression") { model.band = .all }
            if !model.report.bands.isEmpty {
                Divider()
                ForEach(model.report.bands) { band in
                    Button(band.label) { model.band = band }
                }
            }
        } label: {
            Label(model.band.shortLabel, systemImage: "line.3.horizontal.decrease.circle")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by tier / remort")
    }

    // MARK: - Footer (lifetime totals)

    private var footer: some View {
        let summary = model.report.summary
        return HStack(spacing: 16) {
            footerStat("Kills", LevelDBFormat.compact(summary.totalKills))
            footerStat("XP", LevelDBFormat.compact(summary.totalXP))
            footerStat("Gold", LevelDBFormat.compact(summary.totalGold))
            footerStat("Deaths", "\(summary.totalDeaths)")
            Spacer()
            if summary.currentLevel > 0 {
                Text("L\(summary.currentLevel) · \(summary.currentBand.shortLabel)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.4))
        .overlay(alignment: .top) { Divider() }
    }

    private func footerStat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.caption.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Reload") { model.reload() }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - Shared small components

/// A labelled metric card used across the leveldb faces.
struct LevelDBStatCard<Accessory: View>: View {
    let label: String
    let value: String
    var unit: String?
    var tint: Color = .primary
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(tint)
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }
}

extension LevelDBStatCard where Accessory == EmptyView {
    init(label: String, value: String, unit: String? = nil, tint: Color = .primary) {
        self.init(label: label, value: value, unit: unit, tint: tint) { EmptyView() }
    }
}

#if DEBUG
    #Preview("Levels — live") {
        let model = LevelDBPanelModel()
        model.preview(.previewSample)
        return LevelDBPanelView(model: model).frame(width: 460, height: 420)
    }
#endif
