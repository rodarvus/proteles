import Foundation
@testable import MudCore
import Testing

@Suite("dinv — narrow report capture", .serialized)
struct DinvReportOwnershipTests {
    private let statsHeader = "                Str    Int    Wis    Dex    Con    Luck   Total"
    private let spells = "Spells Bonus  :  28     49     40     70     37     20     244"

    @Test("Stats survive unrelated output and input before and after the bonus row")
    func statsDuringPlay() async throws {
        let driver = try await statsDriver()
        await driver.send("scan minion")
        let room = await driver.engine.process(line: "A traveler arrives from the north.")
        #expect(!room.gag)
        let header = await driver.engine.process(line: statsHeader)
        #expect(header.gag)
        await driver.apply(header.effects)
        let row = await driver.engine.process(line: spells)
        #expect(row.gag)
        await driver.apply(row.effects)
        await driver.lua("assert(inv.statBonus.currentBonus.str == 7)")
        await driver.send("quest req")
        await acknowledge(driver)
        await driver.lua("""
        assert(testStats == DRL_RET_SUCCESS)
        assert(inv.statBonus.currentBonus.str == 28)
        assert(inv.statBonus.spellBonus[150].ave.int == 49)
        """)
        #expect(!driver.sent.contains { $0.contains("inv.statBonus") })
        #expect(!driver.notes.contains { $0.contains("resource busy") })
    }

    @Test("Conflicting stats and timeout retain the prior bonuses", arguments: ["stats", "st", "timeout"])
    func incompleteStats(conflict: String) async throws {
        let driver = try await statsDriver()
        await driver.receive(statsHeader)
        if conflict == "timeout" { await driver.advance(11) } else { await driver.send(conflict) }
        await driver.receive(spells)
        await acknowledge(driver)
        await driver.lua("""
        assert(testStats ~= DRL_RET_SUCCESS)
        assert(inv.statBonus.currentBonus.str == 7)
        assert(inv.statBonus.spellBonus[150] == nil)
        """)
    }

    @Test("Only a complete wish report publishes; unrelated chat remains visible", arguments: [true, false])
    func wishes(complete: Bool) async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        driver.echoes = false
        await driver.lua("""
        dbot.wish.table = {OldWish=true}
        inv.runtime.start(function()
          testWish = dbot.execute.safe.blocking({'wish list'}, dbot.wish.setupFn, nil,
            dbot.wish.resultFn, 10, {conflicts={wish=true},
              captureComplete=function() return dbot.wish.captureCompleted end})
        end)
        """)
        await driver.advance(0.1)
        await acknowledge(driver)
        await driver.receive("                                    Base Cost Adjustment Your Cost  Keyword")
        await driver.send("map")
        let chat = await driver.engine.process(line: "A friend tells you 'hello'.")
        #expect(!chat.gag)
        await driver.receive("*Portal wear location                    6000        150        -- Portal    ")
        await driver.lua("assert(dbot.wish.has('OldWish')); assert(not dbot.wish.has('Portal'))")
        if complete {
            await driver.receive("Refer to 'help wish' for a description of each wish.")
            await driver.send("quest req")
        }
        await acknowledge(driver)
        await driver.lua("""
        assert((testWish == DRL_RET_SUCCESS) == \(complete))
        assert(dbot.wish.has('Portal') == \(complete))
        assert(dbot.wish.has('OldWish') ~= \(complete))
        """)
    }

    private func statsDriver() async throws -> DinvCoordinatorDriver {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        driver.echoes = false
        await driver.lua("""
        inv.statBonus.currentBonus.str = 7
        inv.runtime.start(function() testStats = inv.statBonus.setCR() end)
        """)
        await driver.advance(0.1)
        await acknowledge(driver)
        #expect(driver.sent.contains("stats"))
        return driver
    }

    private func acknowledge(_ driver: DinvCoordinatorDriver) async {
        if let marker = driver.sent.last(where: { $0.hasPrefix("echo ") }) {
            await driver.receive(String(marker.dropFirst(5)))
            await driver.advance(0.1)
        }
    }
}
