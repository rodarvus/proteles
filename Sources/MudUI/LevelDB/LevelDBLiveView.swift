import MudCore
import SwiftUI

/// **Live HUD** (design B): a glanceable "am I grinding efficiently right now?"
/// view, derived from the last hour + today off the DB (no plugin coupling).
struct LevelDBLiveView: View {
    let report: LevelDBReport

    private var live: LevelDBLiveStats {
        report.live
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 12) {
                LevelDBStatCard(
                    label: "XP / hour",
                    value: LevelDBFormat.compact(live.xpPerHour),
                    tint: .orange
                )
                nextLevelCard
                LevelDBStatCard(
                    label: "Kills / min",
                    value: LevelDBFormat.decimal(live.killsPerMinute),
                    tint: .primary
                ) {
                    Text(live.recentCombatSeconds > 0
                        ? "avg combat \(LevelDBFormat.decimal(live.recentCombatSeconds))s"
                        : "last hour")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            bestZoneCard
            todayCard

            if live.lastHourKills == 0 {
                Text("No kills in the last hour — numbers reflect today and your history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var nextLevelCard: some View {
        LevelDBStatCard(
            label: "Next level in",
            value: live.minutesToNextLevel.map { LevelDBFormat.duration($0 * 60) } ?? "—",
            tint: .teal
        ) {
            Text(report.summary.currentLevel > 0
                ? "at current pace · L\(report.summary.currentLevel) → \(report.summary.currentLevel + 1)"
                : "at current pace")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bestZoneCard: some View {
        if let zone = live.bestZone {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("BEST ZONE — \(zone.zone.uppercased())")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(LevelDBFormat.decimal(zone.xpPerSecond)) XP/sec")
                        .font(.caption.monospacedDigit()).foregroundStyle(.green)
                }
                ProgressView(value: 1).tint(.green)
                Text("\(LevelDBFormat.grouped(zone.kills)) kills · \(LevelDBFormat.compact(zone.xp)) XP "
                    + "in this band")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TODAY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            row("Kills", LevelDBFormat.grouped(live.todayKills))
            row("XP", LevelDBFormat.grouped(live.todayXP), tint: .orange)
            row("Gold", LevelDBFormat.compact(live.todayGold), tint: .yellow)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private func row(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Text(value).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(tint)
        }
    }
}
