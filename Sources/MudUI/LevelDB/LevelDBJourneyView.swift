import MudCore
import SwiftUI

/// **The journey** (design D): the whole progression as a story — a chapter per
/// tier/remort with its span and best zone, plus a daily activity heatmap.
struct LevelDBJourneyView: View {
    let report: LevelDBReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(report.chapters.enumerated()), id: \.element.id) { index, chapter in
                chapterCard(chapter, isCurrent: index == 0)
            }
            if report.chapters.isEmpty {
                Text("No progression recorded yet.").font(.callout).foregroundStyle(.secondary)
            }
            heatmap
        }
    }

    private func chapterCard(_ chapter: LevelDBChapter, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Rectangle()
                .fill(isCurrent ? Color.orange : Color.teal)
                .frame(width: 3)
                .cornerRadius(1.5)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chapter.band.label)
                        .font(.headline)
                        .foregroundStyle(isCurrent ? .orange : .teal)
                    Spacer()
                    Text(isCurrent ? "in progress" : spanLabel(chapter))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Levels \(chapter.minLevel) → \(chapter.maxLevel)")
                    Spacer()
                    Text("\(LevelDBFormat.grouped(chapter.kills)) kills")
                        .foregroundStyle(.secondary)
                }
                .font(.callout.monospacedDigit())
                HStack {
                    if let zone = chapter.bestZone {
                        Text("Best zone ").foregroundStyle(.secondary)
                            + Text(zone).foregroundStyle(.green).bold()
                    }
                    Spacer()
                    Text("\(chapter.deaths) death\(chapter.deaths == 1 ? "" : "s")")
                        .foregroundStyle(chapter.deaths > 0 ? .red : .secondary)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private func spanLabel(_ chapter: LevelDBChapter) -> String {
        guard let first = chapter.firstSeen, let last = chapter.lastSeen else { return "completed" }
        let days = Int((last.timeIntervalSince(first) / 86400).rounded())
        return days <= 0 ? "1 day" : "\(days) days"
    }

    // MARK: - Activity heatmap

    @ViewBuilder
    private var heatmap: some View {
        // Oldest→newest, last ~26 weeks.
        let days = Array(report.daily.prefix(182)).reversed().map(\.self)
        let maxXP = max(1, days.map(\.xp).max() ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVITY — LAST \(days.count) DAYS")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if days.isEmpty {
                Text("No activity recorded yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 26),
                    spacing: 3
                ) {
                    ForEach(days) { day in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(heatColor(day.xp, max: maxXP))
                            .aspectRatio(1, contentMode: .fit)
                            .help("\(day.day): \(LevelDBFormat.grouped(day.xp)) XP")
                    }
                }
                Text("darker → brighter = more XP that day")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private func heatColor(_ xp: Int, max: Int) -> Color {
        guard xp > 0 else { return Color.gray.opacity(0.18) }
        let ratio = Double(xp) / Double(max)
        let bucket = ratio > 0.66 ? 1.0 : ratio > 0.33 ? 0.7 : 0.45
        return Color.green.opacity(0.25 + bucket * 0.6)
    }
}
