import Charts
import MudCore
import SwiftUI

/// **Analytics** (design C): a retrospective deep-dive in Swift Charts — zone
/// efficiency, daily XP, and the level curve over time.
struct LevelDBAnalyticsView: View {
    let report: LevelDBReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            zoneEfficiency
            dailyXP
            levelCurve
        }
    }

    // MARK: - XP/sec by zone (top 8)

    @ViewBuilder
    private var zoneEfficiency: some View {
        let zones = Array(report.zones.sorted { $0.xpPerSecond > $1.xpPerSecond }.prefix(8))
        section("XP / sec by zone") {
            if zones.isEmpty {
                emptyNote
            } else {
                Chart(zones) { zone in
                    BarMark(
                        x: .value("XP/sec", zone.xpPerSecond),
                        y: .value("Zone", zone.zone)
                    )
                    .foregroundStyle(.orange.gradient)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(LevelDBFormat.decimal(zone.xpPerSecond))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(zones.count) * 26 + 10)
            }
        }
    }

    // MARK: - Daily XP (last 14 days)

    @ViewBuilder
    private var dailyXP: some View {
        // `daily` is newest-first; chart oldest→newest.
        let days = Array(report.daily.prefix(14)).reversed().map(\.self)
        section("Daily XP — last \(days.count) days") {
            if days.isEmpty {
                emptyNote
            } else {
                Chart(days) { day in
                    LineMark(x: .value("Day", day.day), y: .value("XP", day.xp))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("Day", day.day), y: .value("XP", day.xp))
                        .foregroundStyle(.orange.opacity(0.12))
                        .interpolationMethod(.catmullRom)
                    if let best = report.summary.bestDay, best.day == day.day {
                        PointMark(x: .value("Day", day.day), y: .value("XP", day.xp))
                            .foregroundStyle(.green)
                            .annotation(position: .top) {
                                Text("\(LevelDBFormat.compact(day.xp))")
                                    .font(.caption2).foregroundStyle(.green)
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let xp = value.as(Int.self) { Text(LevelDBFormat.compact(xp)) }
                        }
                    }
                }
                .frame(height: 150)
            }
        }
    }

    // MARK: - Level curve over time

    private var levelCurve: some View {
        section("Level curve over time") {
            if report.levelCurve.count < 2 {
                emptyNote
            } else {
                Chart(report.levelCurve) { point in
                    LineMark(x: .value("When", point.timestamp), y: .value("Level", point.level))
                        .foregroundStyle(.teal)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisValueLabel(format: .dateTime.month().year(.twoDigits))
                    }
                }
                .frame(height: 130)
                Text("Each remort resets the level to 1; steeper = faster leveling.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private var emptyNote: some View {
        Text("Not enough data yet.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
    }
}
