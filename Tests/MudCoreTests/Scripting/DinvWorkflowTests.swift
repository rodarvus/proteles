import Foundation
@testable import MudCore
import Testing

@Suite("dinv — interrupted equipment and report ownership", .serialized)
struct DinvWorkflowTests {
    @Test(
        "Running between equipment stages resumes or stops with cleanup",
        arguments: ["resume", "cancel", "timeout"]
    )
    func runningDuringWear(ending: String) async throws {
        let driver = try await equipmentDriver()
        await driver.lua("""
        inv.runtime.start(function() testWear = inv.set.wear({wielded={id=202}}) end)
        """)
        await driver.advance(0.2)
        for _ in 0..<12 where !driver.sent.contains("put 201 999") {
            await acknowledge(driver)
        }
        #expect(driver.sent.contains("put 201 999"))
        await acknowledge(driver)
        await driver.apply(driver.engine.applyGMCP(package: "char.status", json: #"{"state":12}"#))
        await acknowledge(driver)
        await driver.advance(1)
        #expect(!driver.sent.contains("wear 202 wielded"))
        await driver.lua("assert(inv.commands.active.phase == 'waitingState')")
        if ending == "cancel" { await driver.lua("inv.runtime.cancelAll(DRL_RET_HALTED)") }
        if ending == "timeout" { await driver.advance(31) }
        driver.echoes = true
        await driver.apply(driver.engine.applyGMCP(package: "char.status", json: #"{"state":3}"#))
        await driver.advance(2)
        if ending == "resume" {
            #expect(driver.sent.filter { $0 == "wear 202 wielded" }.count == 1)
            await driver.lua("""
            assert(testWear == DRL_RET_SUCCESS)
            assert(inv.items.getField(202, invFieldObjLoc) == 'wielded')
            """)
        } else {
            #expect(!driver.sent.contains("wear 202 wielded"))
            #expect(driver.notes.contains { $0.contains("Equipment change interrupted") })
        }
        await driver.lua("assert(inv.state == invStateIdle); assert(inv.commands.leaseOwner == nil)")
    }

    @Test("A canceled opening fence stays hidden and cannot dispatch the request")
    func canceledPrefix() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        driver.echoes = false
        await driver.lua("inv.runtime.start(function() dbot.pagesize.get() end)")
        await driver.advance(0.1)
        let marker = try #require(driver.sent.last)
        await driver.send("pagesize 20")
        let response = await driver.engine.process(line: String(marker.dropFirst(5)))
        #expect(response.gag)
        await driver.apply(response.effects)
        await driver.advance(1)
        #expect(!driver.sent.contains("pagesize"))
    }

    @Test("Wish admission in combat sends no pagesize query or fence")
    func wishesInCombat() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.apply(driver.engine.applyGMCP(package: "char.status", json: #"{"state":8}"#))
        await driver.lua("dbot.wish.get()")
        await driver.advance(1)
        #expect(driver.sent.isEmpty)
    }

    @Test("A rejected wear cannot be reported as a successful set")
    func rejectedWear() async throws {
        let driver = try await equipmentDriver()
        driver.replies["wear 202 wielded"] = ["You cannot wield that."]
        driver.echoes = true
        await driver.lua("""
        inv.runtime.start(function() testWear = inv.set.wear({wielded={id=202}}) end)
        """)
        await driver.advance(2)
        await driver.lua("""
        assert(testWear == DRL_RET_MISSING_ENTRY)
        assert(inv.state == invStateIdle); assert(inv.commands.leaseOwner == nil)
        """)
        #expect(driver.notes.contains { $0.contains("Equipment set incomplete at wielded") })
        #expect(!driver.notes.contains { $0.contains("Wore 1 new item") })
    }

    private func equipmentDriver() async throws -> DinvCoordinatorDriver {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        driver.echoes = false
        driver.replies = [
            "remove 201": ["{invmon}1,201,-1,24"],
            "put 201 999": ["{invmon}6,201,999,-1"],
            "get 202 999": ["{invmon}5,202,999,-1"],
            "wear 202 wielded": ["{invmon}2,202,-1,24"]
        ]
        await driver.lua("""
        inv.config.table.isBuildExecuted = true
        for _, id in ipairs({201,202,999}) do inv.items.new(id) end
        inv.items.setField(201, invFieldObjLoc, 'wielded')
        inv.items.setField(201, invFieldHomeContainer, 999)
        inv.items.setField(202, invFieldObjLoc, 999)
        inv.items.setField(999, invFieldObjLoc, invItemLocInventory)
        """)
        return driver
    }

    private func acknowledge(_ driver: DinvCoordinatorDriver) async {
        if let marker = driver.sent.last, marker.hasPrefix("echo ") {
            await driver.receive(String(marker.dropFirst(5)))
            await driver.advance(0.1)
        }
    }
}
