#if DEBUG
    import Foundation
    import MudCore

    extension LevelDBReport {
        /// A representative report for SwiftUI previews (no disk access).
        static var previewSample: LevelDBReport {
            var report = LevelDBReport()
            var summary = LevelDBSummary()
            summary.totalKills = 52449
            summary.totalXP = 11_219_400
            summary.totalGold = 118_534_077
            summary.totalDeaths = 20
            summary.totalQuests = 693
            summary.totalCampaigns = 1013
            summary.currentLevel = 73
            summary.currentTier = 4
            summary.currentRemort = 5
            summary.bestDay = LevelDBDaily(day: "2026-05-27", kills: 2400, xp: 497_982)
            report.summary = summary
            report.band = LevelDBBand(tier: 4, remort: 5)

            report.zones = [
                LevelDBZoneStat(zone: "verume", kills: 877, xp: 212_659, gold: 41000, combatSeconds: 2150),
                LevelDBZoneStat(zone: "transcend", kills: 160, xp: 14164, gold: 3200, combatSeconds: 157),
                LevelDBZoneStat(zone: "conflict", kills: 152, xp: 21846, gold: 5100, combatSeconds: 304),
                LevelDBZoneStat(zone: "fortune", kills: 535, xp: 90321, gold: 18000, combatSeconds: 1411)
            ]
            report.mobs = [
                LevelDBMobStat(mob: "a hedge knight", zone: "verume", kills: 410, xp: 99300),
                LevelDBMobStat(mob: "a fortune teller", zone: "fortune", kills: 220, xp: 41000)
            ]
            var quests = LevelDBObjectiveStat()
            quests.attempts = 693; quests.succeeded = 660; quests.totalQP = 18400
            quests.totalDuration = 693 * 600; quests.totalGold = 1_200_000
            report.quests = quests

            report.daily = (0..<30).map { offset in
                LevelDBDaily(
                    day: "2026-05-\(String(format: "%02d", 30 - offset))",
                    kills: 200 + offset * 7,
                    xp: 80000 + (offset % 6) * 70000
                )
            }
            report.goldSources = [
                LevelDBGoldSource(source: "mob", amount: 48_194_410),
                LevelDBGoldSource(source: "sell", amount: 44_410_022),
                LevelDBGoldSource(source: "haggle", amount: 12_370_134)
            ]
            report.bands = [LevelDBBand(tier: 4, remort: 5), LevelDBBand(tier: 3, remort: 7)]
            report.chapters = [
                LevelDBChapter(
                    band: LevelDBBand(tier: 4, remort: 5),
                    kills: 11400,
                    deaths: 4,
                    minLevel: 2,
                    maxLevel: 73,
                    bestZone: "verume",
                    firstSeen: Date(timeIntervalSince1970: 1_746_000_000),
                    lastSeen: Date(timeIntervalSince1970: 1_748_500_000)
                ),
                LevelDBChapter(
                    band: LevelDBBand(tier: 3, remort: 7),
                    kills: 3398,
                    deaths: 9,
                    minLevel: 2,
                    maxLevel: 200,
                    bestZone: "fortune",
                    firstSeen: Date(timeIntervalSince1970: 1_745_000_000),
                    lastSeen: Date(timeIntervalSince1970: 1_745_800_000)
                )
            ]
            var live = LevelDBLiveStats()
            live.todayKills = 883; live.todayXP = 137_674; live.todayGold = 1_200_000
            live.lastHourXP = 214_000; live.lastHourKills = 540; live.recentCombatSeconds = 6.6
            live.bestZone = report.zones.first; live.xpPerLevelEstimate = 24000
            report.live = live
            return report
        }
    }
#endif
