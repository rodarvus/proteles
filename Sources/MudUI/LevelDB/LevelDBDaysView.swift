import Charts
import MudCore
import SwiftUI

/// The **Days** tab (#12): a rich daily explorer. Left, the day list with
/// headline badges; right, the selected day's story — summary cards, an
/// hour-by-hour activity strip, and the chronological timeline of levels,
/// pups, campaigns, quests, GQs, and deaths.
struct LevelDBDaysView: View {
    @Bindable var model: LevelDBPanelModel

    var body: some View {
        HSplitView {
            dayList
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dayList: some View {
        List(model.insights.days, selection: $model.selectedDay) { day in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(LevelDBDayLabel.title(day.day)).font(.callout.weight(.medium))
                    Spacer()
                    Text(LevelDBFormat.compact(day.xp) + " xp")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    badge("\(day.levels) lv", show: day.levels > 0, tint: .green)
                    badge("\(day.pups) pup", show: day.pups > 0, tint: .mint)
                    badge("\(day.campaignsDone) cp", show: day.campaignsDone > 0, tint: .blue)
                    badge("\(day.questsDone) q", show: day.questsDone > 0, tint: .indigo)
                    badge("\(day.gquests) gq", show: day.gquests > 0, tint: .purple)
                    badge("\(day.deaths)☠", show: day.deaths > 0, tint: .red)
                }
            }
            .tag(day.day)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func badge(_ text: String, show: Bool, tint: Color) -> some View {
        if show {
            Text(text)
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(tint.opacity(0.18), in: Capsule())
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let detail = model.dayDetail {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCards(detail.summary)
                    if !detail.hourly.isEmpty { hourStrip(detail.hourly) }
                    timeline(detail.events)
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "Pick a day",
                systemImage: "calendar",
                description: Text("Each day tells its story: levels, pups, campaigns, quests, deaths.")
            )
        }
    }

    private func summaryCards(_ day: LevelDBDaySummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LevelDBDayLabel.title(day.day)).font(.title3.weight(.semibold))
            LazyVGrid(
                columns: Array(repeating: .init(.flexible(), alignment: .leading), count: 4),
                spacing: 8
            ) {
                stat("XP", LevelDBFormat.compact(day.xp))
                stat("Kills", LevelDBFormat.grouped(day.kills))
                stat("Played", LevelDBFormat.duration(Double(day.activeSeconds)))
                stat("QP", "\(day.qpEarned)")
                stat("Levels", "\(day.levels)")
                stat("Pups", "\(day.pups)")
                stat("Campaigns", "\(day.campaignsDone)")
                stat("Gold", LevelDBFormat.compact(day.goldEarned))
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private func hourStrip(_ hourly: [LevelDBHourBucket]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity by hour").font(.caption).foregroundStyle(.secondary)
            Chart(hourly) { bucket in
                BarMark(
                    x: .value("Hour", bucket.hour),
                    y: .value("XP", bucket.xp)
                )
                .foregroundStyle(.teal)
            }
            .chartXScale(domain: 0...23)
            .frame(height: 70)
        }
    }

    private func timeline(_ events: [LevelDBDayEvent]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timeline").font(.caption).foregroundStyle(.secondary)
            ForEach(events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.timestamp.formatted(.dateTime.hour().minute()))
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        .frame(width: 48, alignment: .trailing)
                    Image(systemName: icon(event.kind))
                        .font(.caption)
                        .foregroundStyle(event.isNegative ? .red : tint(event.kind))
                        .frame(width: 16)
                    Text(event.title).font(.callout)
                        .foregroundStyle(event.isNegative ? .red : .primary)
                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func icon(_ kind: LevelDBDayEvent.Kind) -> String {
        switch kind {
        case .level: "arrow.up.circle.fill"
        case .pup: "sparkles"
        case .campaign: "target"
        case .quest: "scroll"
        case .gquest: "globe"
        case .death: "xmark.octagon.fill"
        }
    }

    private func tint(_ kind: LevelDBDayEvent.Kind) -> Color {
        switch kind {
        case .level: .green
        case .pup: .mint
        case .campaign: .blue
        case .quest: .indigo
        case .gquest: .purple
        case .death: .red
        }
    }
}

/// "2026-06-10" → "Tue, Jun 10" (today/yesterday get words).
enum LevelDBDayLabel {
    /// Shared parser — a fresh DateFormatter per row was a measurable
    /// allocation in the Days list render (2026-06 audit); NSFormatter is
    /// documented thread-safe for parsing/formatting.
    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func title(_ day: String) -> String {
        guard let date = dayParser.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
