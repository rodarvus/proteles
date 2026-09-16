import Foundation
@testable import MudCore
import Testing

@Suite("dinv — portal input interference", .serialized)
struct DinvPortalInterferenceTests {
    @Test("Harmless input preserves portal entry and restoration", arguments: ["none", "hold", "finish"])
    func unrelatedInput(phase: String) async throws {
        let driver = try await preparedHop()
        if phase == "finish" {
            await acknowledgeFence(driver)
        }
        let pendingFence = try #require(driver.sent.last)
        if phase == "finish" {
            // Recording: spell sent after the finish prefix reply, before its
            // deferred command dispatch. The original equipment must survive.
            await driver.receive(String(pendingFence.dropFirst(5)))
            await driver.send("cast 'energy shield'")
        } else if phase == "hold" {
            // Recording: eq sent while hold is awaiting its suffix fence.
            await driver.send("eq")
            await driver.receive(String(pendingFence.dropFirst(5)))
        } else {
            await driver.receive(String(pendingFence.dropFirst(5)))
        }
        driver.echoes = true
        await driver.advance(1)
        let actions = driver.sent.filter { !$0.hasPrefix("echo ") }
        #expect(actions.suffix(3) == ["enter", "wear 101 portal", "put 102 999"])
        #expect(actions.filter { $0 == "enter" }.count == 1)
        await driver.lua("""
        assert(inv.items.getField(101, invFieldObjLoc) == inv.wearLoc[invWearableLocPortal])
        local location = inv.items.getField(102, invFieldObjLoc)
        assert(tonumber(location) == 999)
        assert(inv.portal.busyUntil == 0); assert(inv.commands.active == nil)
        """)
    }

    @Test("A changed portal slot prevents entry and replacement", arguments: ["hold", "finish"])
    func changedSlotBeforeEntry(phase: String) async throws {
        let driver = try await preparedHop()
        if phase == "finish" {
            await acknowledgeFence(driver)
        }
        // The hold was verified when the finish request was queued. A later
        // equipment change must still prevent entering a different portal.
        await driver.receive("{invmon}1,102,-1,31", "{invmon}2,103,-1,31")
        driver.echoes = true
        await acknowledgeFence(driver)
        await driver.advance(1)
        #expect(!driver.sent.contains("enter"))
        #expect(!driver.sent.contains("wear 101 portal"))
        await driver.lua("assert(inv.portal.busyUntil == 0)")
    }

    @Test("A failed hold still restores the original item to an empty slot")
    func failedHold() async throws {
        let driver = try await preparedHop(holdSucceeds: false)
        driver.echoes = true
        await acknowledgeFence(driver)
        await driver.advance(1)
        #expect(!driver.sent.contains("enter"))
        #expect(driver.sent.filter { $0 == "wear 101 portal" }.count == 1)
        #expect(driver.sent.filter { $0 == "put 102 999" }.count == 1)
        await driver.lua("assert(inv.portal.isAtTargetSlot(101, true)); assert(inv.portal.busyUntil == 0)")
    }

    @Test("Explicit cancellation still stops a portal hop")
    func explicitCancellation() async throws {
        let driver = try await preparedHop()
        await driver.lua("inv.runtime.cancelAll(DRL_RET_HALTED)")
        await acknowledgeFence(driver)
        await driver.advance(30)
        #expect(!driver.sent.contains("enter"))
        #expect(!driver.sent.contains("wear 101 portal"))
        await driver.lua("assert(inv.commands.active == nil); assert(inv.portal.busyUntil == 0)")
    }

    @Test("A gear change cannot stow the restoration item between portal hold and entry")
    func gearDuringPortalHop() async throws {
        let driver = try await preparedHop()
        driver.replies["put 101 999"] = ["{invmon}6,101,999,-1"]
        driver.replies["wear 103 portal"] = ["{invmon}2,103,-1,31"]
        await driver.lua("""
        inv.items.setField(101, invFieldHomeContainer, 999)
        inv.runtime.start(function() testGear = inv.set.wear({portal={id=103}}) end)
        """)
        driver.echoes = true
        await acknowledgeFence(driver)
        await driver.advance(2)
        let restore = try #require(driver.sent.firstIndex(of: "wear 101 portal"))
        let stow = try #require(driver.sent.firstIndex(of: "put 101 999"))
        #expect(restore < stow)
        await driver.lua("""
        assert(testGear == DRL_RET_SUCCESS)
        assert(inv.items.getField(103, invFieldObjLoc) == 'portal')
        assert(inv.commands.leaseOwner == nil)
        """)
    }

    @Test("Portal restoration failure is reported even when its fence succeeds")
    func rejectedRestoration() async throws {
        let driver = try await preparedHop()
        driver.replies["wear 101 portal"] = ["You do not have that item."]
        driver.replies["put 102 999"] = ["You don't have that."]
        driver.echoes = true
        await acknowledgeFence(driver)
        await driver.advance(1)
        #expect(driver.notes.contains { $0.contains("restoration unconfirmed") })
        await driver.lua("assert(inv.commands.leaseOwner == nil); assert(not inv.portal.inProgress)")
    }

    @Test("A queued portal observes equipment only after the preceding gear change finishes")
    func portalDuringGearChange() async throws {
        let driver = try await preparedHop()
        driver.echoes = true
        await acknowledgeFence(driver)
        await driver.advance(1)
        driver.sent.removeAll()
        driver.echoes = false
        driver.replies["remove 103"] = ["{invmon}1,103,-1,31"]
        driver.replies["wear 103 portal"] = ["{invmon}1,102,-1,31", "{invmon}2,103,-1,31"]
        await driver.lua("inv.runtime.start(function() inv.set.wear({portal={id=103}}) end)")
        await driver.advance(0.1)
        await driver.lua("assert(inv.portal.use('102') == DRL_RET_SUCCESS)")
        driver.echoes = true
        await acknowledgeFence(driver)
        await driver.advance(2)
        let gear = try #require(driver.sent.firstIndex(of: "wear 103 portal"))
        let hold = try #require(driver.sent.firstIndex(of: "hold 102"))
        #expect(gear < hold)
        #expect(driver.sent.filter { $0 == "wear 103 portal" }.count == 2)
        #expect(!driver.sent.contains("wear 101 portal"))
        await driver
            .lua("assert(inv.portal.isAtTargetSlot(103, true)); assert(inv.commands.leaseOwner == nil)")
    }

    @Test("Equipment command bursts tolerate eq while awaiting their prefix")
    func equipmentBurst() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        driver.echoes = false
        await driver.lua("""
        inv.runtime.start(function()
          testResult = dbot.execute.safe.blocking({'wear 101 portal'}, nil, nil,
            dbot.callback.default, 10)
        end)
        """)
        await driver.advance(0.1)
        let prefix = try #require(driver.sent.last)
        await driver.send("eq")
        driver.echoes = true
        let response = await driver.engine.process(line: String(prefix.dropFirst(5)))
        #expect(response.gag, "The pending command fence must remain hidden after eq")
        await driver.apply(response.effects)
        await driver.advance(1)
        #expect(driver.sent.filter { $0 == "wear 101 portal" }.count == 1)
        await driver.lua("assert(testResult == DRL_RET_SUCCESS)")
    }

    private func preparedHop(holdSucceeds: Bool = true) async throws -> DinvCoordinatorDriver {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        driver.echoes = false
        driver.replies = [
            "remove 101": ["{invmon}1,101,-1,31"],
            "get 102 999": ["{invmon}5,102,999,-1"],
            "hold 102": ["{invmon}2,102,-1,31"],
            "wear 101 portal": ["{invmon}1,102,-1,31", "{invmon}2,101,-1,31"],
            "put 102 999": ["{invmon}6,102,999,-1"]
        ]
        if !holdSucceeds {
            driver.replies["hold 102"] = ["You cannot hold that."]
        }
        await driver.lua("""
        inv.config.table.isBuildExecuted = true
        for _, id in ipairs({101, 102, 103, 999}) do inv.items.new(id) end
        inv.items.setField(101, invFieldObjLoc, inv.wearLoc[invWearableLocPortal])
        inv.items.setField(102, invFieldObjLoc, 999)
        inv.items.setField(103, invFieldObjLoc, invItemLocInventory)
        inv.items.setField(999, invFieldObjLoc, invItemLocInventory)
        dbot.wish.has = function(name) return name == 'Portal' end
        assert(inv.portal.use('102') == DRL_RET_SUCCESS)
        """)
        await driver.advance(0.1)
        await acknowledgeFence(driver)
        #expect(driver.sent.contains("hold 102"))
        await driver.lua("assert(inv.portal.isAtTargetSlot(102, true) == \(holdSucceeds))")
        return driver
    }

    private func acknowledgeFence(_ driver: DinvCoordinatorDriver) async {
        guard let command = driver.sent.last, command.hasPrefix("echo { DINV fence ") else {
            Issue.record("Expected a pending dinv fence")
            return
        }
        await driver.receive(String(command.dropFirst(5)))
        await driver.advance(0.1)
    }
}
