import MudCore
import SwiftUI

/// **Faithful reports** (design A): leveldb's own `ldb` reports as native,
/// sortable tables. A left nav picks the report; the active band filter applies.
struct LevelDBReportsView: View {
    @Bindable var model: LevelDBPanelModel

    private var report: LevelDBReport {
        model.report
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            nav
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if model.reportTab == .zones { sortBar }
                table
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(LevelDBPanelModel.ReportTab.allCases) { tab in
                Button {
                    model.reportTab = tab
                } label: {
                    Text(tab.label)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(
                            model.reportTab == tab ? Color.accentColor.opacity(0.85) : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(model.reportTab == tab ? Color.white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 130)
    }

    private var sortBar: some View {
        HStack(spacing: 8) {
            Text("Sort").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $model.zoneSort) {
                ForEach(LevelDBStore.ZoneSort.allCases, id: \.self) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .labelsHidden().fixedSize()
        }
    }

    @ViewBuilder
    private var table: some View {
        switch model.reportTab {
        case .zones: zonesTable
        case .mobs: mobsTable
        case .quests: objectiveTable(report.quests, kind: "Quests")
        case .campaigns: objectiveTable(report.campaigns, kind: "Campaigns")
        case .globalQuests: objectiveTable(report.globalQuests, kind: "Global quests")
        case .gold: goldTable
        case .deaths: deathsTable
        case .daily: dailyTable
        }
    }

    // MARK: - Tables

    private var zonesTable: some View {
        reportGrid(
            headers: [("Zone", .leading), ("Kills", .trailing), ("XP", .trailing), ("XP/sec", .trailing)],
            rows: report.zones,
            empty: "No kills recorded for this band."
        ) { zone in
            [
                .text(zone.zone, .leading),
                .text(LevelDBFormat.grouped(zone.kills), .trailing),
                .text(LevelDBFormat.compact(zone.xp), .trailing),
                .colored(LevelDBFormat.decimal(zone.xpPerSecond), .green, .trailing)
            ]
        }
    }

    private var mobsTable: some View {
        reportGrid(
            headers: [("Mob", .leading), ("Zone", .leading), ("Kills", .trailing), ("XP", .trailing)],
            rows: report.mobs,
            empty: "No kills recorded for this band."
        ) { mob in
            [
                .text(mob.mob, .leading),
                .dim(mob.zone, .leading),
                .text(LevelDBFormat.grouped(mob.kills), .trailing),
                .text(LevelDBFormat.compact(mob.xp), .trailing)
            ]
        }
    }

    private var goldTable: some View {
        reportGrid(
            headers: [("Source", .leading), ("Gold", .trailing), ("Share", .trailing)],
            rows: report.goldSources,
            empty: "No gold recorded."
        ) { source in
            let total = max(1, report.summary.totalGold)
            let pct = Double(source.amount) / Double(total) * 100
            return [
                .text(source.source, .leading),
                .colored(LevelDBFormat.grouped(source.amount), .yellow, .trailing),
                .dim("\(LevelDBFormat.decimal(pct))%", .trailing)
            ]
        }
    }

    private var deathsTable: some View {
        reportGrid(
            headers: [("When", .leading), ("Killed by", .leading), ("Zone", .leading), ("Lv", .trailing)],
            rows: report.deaths,
            empty: "No deaths in this band — nicely done."
        ) { death in
            [
                .dim(death.timestamp.formatted(date: .abbreviated, time: .shortened), .leading),
                .text(death.mob, .leading),
                .dim(death.zone, .leading),
                .text("\(death.level)", .trailing)
            ]
        }
    }

    private var dailyTable: some View {
        reportGrid(
            headers: [("Day", .leading), ("Kills", .trailing), ("XP", .trailing)],
            rows: report.daily,
            empty: "No daily data."
        ) { day in
            [
                .text(day.day, .leading),
                .text(LevelDBFormat.grouped(day.kills), .trailing),
                .colored(LevelDBFormat.compact(day.xp), .orange, .trailing)
            ]
        }
    }

    private func objectiveTable(_ stat: LevelDBObjectiveStat, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if stat.attempts == 0 {
                emptyNote("No \(kind.lowercased()) recorded for this band.")
            } else {
                summaryRow("Completed", "\(stat.succeeded) / \(stat.attempts)")
                summaryRow("Success rate", "\(LevelDBFormat.decimal(stat.successRate * 100))%")
                summaryRow("Average QP", LevelDBFormat.decimal(stat.averageQP))
                summaryRow("Average time", LevelDBFormat.duration(stat.averageDurationSeconds))
                summaryRow("Total QP", LevelDBFormat.grouped(stat.totalQP))
                summaryRow("Total gold", LevelDBFormat.compact(stat.totalGold))
                summaryRow("Trains / Pracs", "\(stat.totalTrains) / \(stat.totalPracs)")
            }
        }
    }

    // MARK: - Generic grid

    private enum Cell {
        case text(String, HorizontalAlignment)
        case dim(String, HorizontalAlignment)
        case colored(String, Color, HorizontalAlignment)
    }

    @ViewBuilder
    private func cellView(_ cell: Cell) -> some View {
        switch cell {
        case .text(let value, let align):
            Text(value).frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
        case .dim(let value, let align):
            Text(value).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
        case .colored(let value, let color, let align):
            Text(value).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
        }
    }

    private func reportGrid<Row: Identifiable>(
        headers: [(String, HorizontalAlignment)],
        rows: [Row],
        empty: String,
        cells: @escaping (Row) -> [Cell]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                emptyNote(empty)
            } else {
                HStack(spacing: 10) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(header.0.uppercased())
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(
                                maxWidth: .infinity,
                                alignment: header.1 == .leading ? .leading : .trailing
                            )
                    }
                }
                .padding(.bottom, 5)
                Divider()
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        ForEach(Array(cells(row).enumerated()), id: \.offset) { _, cell in
                            cellView(cell)
                        }
                    }
                    .font(.callout.monospacedDigit())
                    .padding(.vertical, 3)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.callout.monospacedDigit().weight(.medium))
            }
            .font(.callout)
            .padding(.vertical, 5)
            Divider().opacity(0.4)
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
    }
}
