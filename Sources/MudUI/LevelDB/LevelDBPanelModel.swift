import Foundation
import MudCore
import Observation
import SwiftUI

/// `@Observable` bridge for the **leveldb** reporting panel. Reads the leveldb
/// plugin's SQLite file (`leveldb.db`) read-only via ``LevelDBStore`` and holds
/// the loaded ``LevelDBReport`` for the SwiftUI views — the plugin stays the
/// sole writer; this panel never mutates its data (PLAN.md D-71). Re-querying is
/// explicit (`reload()`), so a running grind doesn't thrash the DB.
@MainActor
@Observable
public final class LevelDBPanelModel {
    /// Which face of the panel is showing. Mirrors the four designed reports:
    /// Live HUD (B), faithful tables (A), analytics charts (C), journey (D).
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case live
        case journey
        case days
        case insights
        case records
        case tables

        public var id: String {
            rawValue
        }

        public var label: String {
            switch self {
            case .live: "Live"
            case .journey: "Journey"
            case .days: "Days"
            case .insights: "Insights"
            case .records: "Records"
            case .tables: "Tables"
            }
        }

        public var systemImage: String {
            switch self {
            case .live: "bolt.fill"
            case .journey: "map"
            case .days: "calendar"
            case .insights: "chart.xyaxis.line"
            case .records: "trophy"
            case .tables: "tablecells"
            }
        }
    }

    /// Which faithful table the Reports face is showing (panel A's left nav).
    public enum ReportTab: String, CaseIterable, Identifiable, Sendable {
        case zones
        case mobs
        case quests
        case campaigns
        case globalQuests
        case gold
        case deaths
        case daily

        public var id: String {
            rawValue
        }

        public var label: String {
            switch self {
            case .zones: "Top zones"
            case .mobs: "Top mobs"
            case .quests: "Quests"
            case .campaigns: "Campaigns"
            case .globalQuests: "Global quests"
            case .gold: "Gold sources"
            case .deaths: "Deaths"
            case .daily: "Daily"
            }
        }
    }

    public private(set) var report = LevelDBReport()
    /// The #12 insight bundle (days, pace, economics, records).
    public private(set) var insights = LevelDBInsightsBundle()
    /// The Days tab's selection + its loaded story.
    public var selectedDay: String? {
        didSet { if oldValue != selectedDay { loadDayDetail() } }
    }

    public private(set) var dayDetail: LevelDBDayDetail?
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    /// `true` when the leveldb DB file doesn't exist yet (plugin never run).
    public private(set) var databaseMissing = false

    public var mode: Mode = .live
    public var reportTab: ReportTab = .zones
    public var zoneSort: LevelDBStore.ZoneSort = .xpPerSecond {
        didSet { if oldValue != zoneSort { reload() } }
    }

    /// The selected progression band; `nil` (all) until the first load picks the
    /// character's current band. Changing it reloads.
    public var band = LevelDBBand.all {
        didSet { if oldValue != band { reload() } }
    }

    /// Override the DB location (tests/previews). `nil` derives the path from
    /// ``character``.
    @ObservationIgnored public var databaseURLOverride: URL?
    /// The connected character, set by the app so the panel reads its
    /// per-character `Databases/<character>/leveldb.db` (#44). Changing it reloads.
    @ObservationIgnored public var character: String? {
        didSet { if oldValue != character { reload() } }
    }

    /// Injectable clock for the live/daily windows (tests).
    @ObservationIgnored public var now: () -> Date = Date.init
    @ObservationIgnored private var hasAutoSelectedBand = false

    public init() {}

    /// Preview/test seam: set a report directly without touching disk.
    public func preview(_ report: LevelDBReport) {
        self.report = report
        databaseMissing = false
    }

    /// (Re)load the report from disk on a background task, then publish on the
    /// main actor. On the very first successful load, snap the filter to the
    /// character's current band so the panel opens on "where am I now?".
    public func reload() {
        let url = databaseURLOverride ?? character.flatMap { try? LevelDBStore.defaultURL(character: $0) }
        guard let url else { databaseMissing = true; return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            databaseMissing = true
            return
        }
        databaseMissing = false
        isLoading = true
        let band = band
        let sort = zoneSort
        let now = now()
        Task {
            let result = await Self.loadOffMain(url: url, band: band, sort: sort, now: now)
            await MainActor.run { self.apply(result) }
        }
    }

    /// Load the selected day's story off-main (#12 Days tab).
    private func loadDayDetail() {
        guard let day = selectedDay else {
            dayDetail = nil
            return
        }
        let url = databaseURLOverride ?? character.flatMap { try? LevelDBStore.defaultURL(character: $0) }
        guard let url else { return }
        Task {
            let detail = await Self.dayDetailOffMain(url: url, day: day)
            await MainActor.run { self.dayDetail = detail }
        }
    }

    private nonisolated static func dayDetailOffMain(url: URL, day: String) async -> LevelDBDayDetail? {
        guard let store = try? LevelDBStore(url: url) else { return nil }
        return try? store.dayDetail(day)
    }

    /// Preview/test seam for the insights bundle.
    public func previewInsights(_ bundle: LevelDBInsightsBundle) {
        insights = bundle
    }

    /// Loaded report, or a human message on failure (kept as a plain enum so it
    /// crosses the actor boundary without needing an `Error` payload).
    enum LoadOutcome {
        case success(LevelDBReport, LevelDBInsightsBundle)
        case failure(String)
    }

    private nonisolated static func loadOffMain(
        url: URL, band: LevelDBBand, sort: LevelDBStore.ZoneSort, now: Date
    ) async -> LoadOutcome {
        do {
            let store = try LevelDBStore(url: url)
            let report = try store.load(band: band, sort: sort, now: now)
            let insights = try store.insights(now: now)
            return .success(report, insights)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func apply(_ result: LoadOutcome) {
        isLoading = false
        switch result {
        case .success(let report, let insights):
            self.report = report
            self.insights = insights
            // Keep the Days selection alive across refreshes; default to the
            // newest day so the tab opens on "today's story".
            if selectedDay == nil || !insights.days.contains(where: { $0.day == selectedDay }) {
                selectedDay = insights.days.first?.day
            } else {
                loadDayDetail() // refresh the open story with new data
            }
            loadError = nil
            if !hasAutoSelectedBand, band.isAll, !report.summary.currentBand.isAll {
                hasAutoSelectedBand = true
                band = report.summary.currentBand // triggers one more reload, scoped
            }
        case .failure(let message):
            loadError = message
        }
    }
}

// MARK: - Formatting helpers

/// Compact human formatting shared by the leveldb views (118M gold, 11.2k XP,
/// 6:40 ETA). Kept here so the views stay declarative.
public enum LevelDBFormat {
    /// Abbreviate a count: 1_234 → "1.2k", 1_234_567 → "1.2M".
    public static func compact(_ value: Int) -> String {
        let n = Double(value)
        switch abs(value) {
        case 1_000_000_000...: return trim(n / 1_000_000_000) + "B"
        case 1_000_000...: return trim(n / 1_000_000) + "M"
        case 10000...: return trim(n / 1000) + "k"
        default: return grouped(value)
        }
    }

    /// Full grouped integer: 1234567 → "1,234,567".
    public static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func decimal(_ value: Double, places: Int = 1) -> String {
        String(format: "%.\(places)f", value)
    }

    /// Seconds → "6:40" / "1:02:05".
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private static func trim(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
