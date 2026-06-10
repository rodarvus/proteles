import Charts
import MudCore
import SwiftUI

/// The **Insights** tab (#12): pace + projection up top ("at this rate…"),
/// best playing hours, and activity economics — what a campaign, quest, or
/// global quest actually pays per minute.
struct LevelDBInsightsView: View {
    let insights: LevelDBInsightsBundle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paceCards
                if insights.pace.daysToRemort != nil { projection }
                if !insights.pace.hourly.isEmpty { bestHours }
                if !insights.economics.isEmpty { economics }
            }
            .padding(12)
        }
    }

    private var paceCards: some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible(), alignment: .leading), count: 3), spacing: 10) {
            card(
                "Level pace (recent)",
                duration(insights.pace.recentLevelSeconds),
                caption: "median of the last 10"
            )
            card(
                "Level pace (band)",
                duration(insights.pace.medianLevelSeconds),
                caption: "median, this remort"
            )
            card(
                "Daily playtime",
                duration(insights.pace.activeSecondsPerDay7d),
                caption: "active, 7-day average"
            )
            card("XP / hour (7d)", rate(insights.pace.xpPerHour7d), caption: "active hours only")
            card("XP / hour (30d)", rate(insights.pace.xpPerHour30d), caption: "active hours only")
            card(
                "Level",
                insights.pace.currentLevel.map(String.init) ?? "—",
                caption: "of \(LevelDBStore.remortCeiling) to remort"
            )
        }
    }

    private var projection: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.teal)
            if let days = insights.pace.daysToRemort {
                Text("At your recent pace and daily playtime, the remort is about ")
                    + Text(days < 1.5 ? "a day away" : "\(Int(days.rounded())) days away")
                    .bold()
                    + Text(".")
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var bestHours: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your best playing hours (XP by hour, last 30 days)")
                .font(.caption).foregroundStyle(.secondary)
            Chart(insights.pace.hourly) { bucket in
                BarMark(x: .value("Hour", bucket.hour), y: .value("XP", bucket.xp))
                    .foregroundStyle(.teal.opacity(0.85))
            }
            .chartXScale(domain: 0...23)
            .frame(height: 90)
        }
    }

    private var economics: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What pays: per-activity economics (successful runs)")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Activity").gridColumnAlignment(.leading)
                    Text("Done")
                    Text("Success")
                    Text("Avg time")
                    Text("Avg qp")
                    Text("QP/min")
                    Text("Avg gold")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(insights.economics) { row in
                    GridRow {
                        Text(row.activity).font(.callout)
                        Text(LevelDBFormat.grouped(row.count))
                        Text(row.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        Text(duration(row.avgDurationSeconds))
                        Text(row.avgQP.map { LevelDBFormat.decimal($0) } ?? "—")
                        Text(row.qpPerMinute.map { LevelDBFormat.decimal($0) } ?? "—").bold()
                        Text(row.avgGold.map { LevelDBFormat.compact(Int($0)) } ?? "—")
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }

    private func card(_ label: String, _ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func duration(_ seconds: Double?) -> String {
        seconds.map { LevelDBFormat.duration($0) } ?? "—"
    }

    private func rate(_ value: Double?) -> String {
        value.map { LevelDBFormat.compact(Int($0)) } ?? "—"
    }
}

/// The **Records** tab (#12): personal bests, lifetime totals, streaks, and
/// the cross-remort speed comparison.
struct LevelDBRecordsView: View {
    let records: LevelDBRecords

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if records.currentStreak > 0 || records.longestStreak > 0 { streaks }
                if !records.bests.isEmpty { section("Personal bests", records.bests, showWhen: true) }
                if !records.lifetime.isEmpty { section("Lifetime", records.lifetime, showWhen: false) }
                if !records.remorts.isEmpty { remorts }
            }
            .padding(12)
        }
    }

    private var streaks: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame.fill").foregroundStyle(.orange)
            Text("Playing streak: ")
                + Text("\(records.currentStreak) day\(records.currentStreak == 1 ? "" : "s")").bold()
                + Text("  ·  longest ever \(records.longestStreak)")
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func section(_ title: String, _ rows: [LevelDBRecords.Best], showWhen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(
                columns: Array(repeating: .init(.flexible(), alignment: .leading), count: 3),
                spacing: 10
            ) {
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                        Text(row.value).font(.callout.monospacedDigit().weight(.semibold))
                        if showWhen, !row.when.isEmpty {
                            Text(LevelDBDayLabel.title(row.when)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var remorts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Leveling speed by remort (median time per level)")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Band")
                    Text("Levels")
                    Text("Median / level")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(records.remorts) { row in
                    GridRow {
                        Text("T\(row.tier) R\(row.remort)")
                        Text(LevelDBFormat.grouped(row.levels))
                        Text(row.medianLevelSeconds.map { LevelDBFormat.duration($0) } ?? "—")
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }
}
