import Foundation
@testable import MudCore
import Testing

/// Real Lua, shim, triggers and SQLite; deterministic clock and simulated wire.
/// These tests do not establish behavior in a connected app session.
@Suite("dinv — owned coordination", .serialized)
struct DinvCoordinatorTests {
    @Test("Startup accepts play before character data and never toggles an unknown prompt")
    func startupLatePrompt() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.lua("inv.cli.runtimeStatus(nil, 'dinv status')")
        await driver.send("look")
        await driver.send("daily blessing")
        await driver.boot()
        await driver.advance(5.658)
        await driver.lua(#"""
        OnPluginTelnetSubnegotiation(201, 'config {"prompt":"YES"}')
        assert(dbot.prompt.isEnabled == true)
        """#)
        await driver.advance(35)
        await driver.lua("assert(inv.init.initializedActive); assert(not inv.items.fullScanCompleted)")
        #expect(!driver.sent.contains("prompt"))
        #expect(driver.sent.filter { $0 == "look" }.count == 1)
        #expect(driver.sent.filter { $0 == "daily blessing" }.count == 1)
    }

    @Test("Complete snapshots publish to SQLite; partial and stale snapshots retain saved rows")
    func stagedSnapshots() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.seed()
        await driver.snapshot()
        await driver.receive("{invdata}", "102,,A test item,1,9,0,0,0")
        await driver.lua("assert(inv.items.table[102] == nil); assert(inv.items.table[101])")
        await driver.receive("{/invdata}")
        await driver.advance(0.1)
        await driver.lua("""
        assert(testResult == DRL_RET_SUCCESS, tostring(testResult))
        assert(inv.items.table[102])
        local count = 0
        for row in dinv_db.handle:nrows('SELECT obj_id FROM items WHERE obj_id=102') do count=count+1 end
        assert(count == 1)
        """)
        await driver.snapshot()
        await driver.receive("{invdata}", "103,,An unfinished item,1,9,0,0,0")
        await driver.advance(31)
        await driver.receive("{/invdata}")
        await driver.lua("""
        assert(testResult == DRL_RET_TIMEOUT)
        assert(inv.items.table[103] == nil); assert(inv.items.table[101])
        assert(inv.items.discoverPkg == nil)
        """)
        await driver.snapshot()
        await driver.receive("{invdata}", "104,,An obsolete item,1,9,0,0,0")
        await driver.lua("inv.items.observeChange('invmon', {1, 101, 0, 0})")
        await driver.send("look")
        await driver.receive("{/invdata}")
        await driver.advance(0.1)
        await driver.lua("assert(testResult == DRL_RET_BUSY); assert(inv.items.table[104] == nil)")
        #expect(driver.sent.filter { $0 == "look" }.count == 1)
    }

    @Test("Caller deadline cancels queued work; a late fence cannot send it")
    func queuedDeadline() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        driver.echoes = false
        await driver.lua("""
        inv.commands.enqueue({'first'}, nil, nil, nil, {})
        testResult = nil
        inv.runtime.start(function()
          local result = dbot.callback.new()
          assert(dbot.execute.safe.commands({'must-never-send'}, nil, nil, dbot.callback.default,
                                           result) == DRL_RET_SUCCESS)
          testResult = dbot.callback.wait(result, 1)
        end)
        """)
        await driver.advance(2)
        await driver.lua("assert(testResult == DRL_RET_TIMEOUT)")
        let marker = try #require(driver.sent.first { $0.hasPrefix("echo ") })
        await driver.receive(String(marker.dropFirst(5)))
        driver.echoes = true
        await driver.advance(40)
        #expect(!driver.sent.contains("must-never-send"))
        await driver.lua("assert(inv.commands.active == nil); assert(next(inv.runtime.tasks) == nil)")
    }

    @Test("Cancel and disable discard continuations, release locks and restore admission")
    func cancellationAndException() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.lua("""
        inv.items.refreshPkg = {endTag=nil}; inv.state=invStateRunning
        inv.runtime.start(function()
          inv.runtime.sleep(1)
          error('injected workflow failure')
        end, inv.items, 'refreshPkg')
        """)
        await driver.advance(2)
        await driver.lua("""
        assert(inv.state == invStateIdle); assert(inv.items.refreshPkg == nil)
        assert(next(inv.runtime.tasks) == nil)
        inv.runtime.start(function()
          inv.runtime.sleep(2)
          inv.commands.send('must-never-send')
        end)
        OnPluginDisable()
        assert(dbot.execute.safe.command('also-never-send') == DRL_RET_UNINITIALIZED)
        """)
        await driver.advance(3)
        await driver.lua("OnPluginEnable(); assert(inv.runtime.enabled)")
        await driver.send("look")
        #expect(!driver.sent.contains("must-never-send"))
        #expect(!driver.sent.contains("also-never-send"))
        #expect(driver.sent.contains("look"))
    }

    @Test("Identification publishes complete matching output and retains old stats on interruption")
    func stagedIdentification() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.seed()
        await driver.lua("""
        testCommands = {}
        assert(inv.items.identifyItem(101, 'identify', {}, testCommands) == DRL_RET_SUCCESS)
        inv.items.trigger.itemIdStats('| Id : 101 |')
        inv.items.trigger.itemIdStats('| Name : Changed item |')
        assert(inv.items.getStatField(101, invStatFieldStr) == 17)
        inv.items.trigger.itemIdEnd(false)
        assert(inv.items.getStatField(101, invStatFieldStr) == 17)
        assert(inv.items.getStatField(101, invStatFieldName) == 'Saved item')
        assert(inv.items.identifyItem(101, 'identify', {}, {}) == DRL_RET_SUCCESS)
        inv.items.trigger.itemIdStats('| Id : 999 |')
        inv.items.trigger.itemIdStats('| Name : Wrong item |')
        assert(inv.items.trigger.itemIdEnd(true) == DRL_RET_BUSY)
        assert(inv.items.getStatField(101, invStatFieldName) == 'Saved item')
        assert(inv.items.identifyItem(101, 'identify', {}, {}) == DRL_RET_SUCCESS)
        inv.items.trigger.itemIdStats('| Name : Updated item |')
        inv.items.trigger.itemIdStats('| Id : 101 |')
        assert(inv.items.trigger.itemIdEnd(true) == DRL_RET_SUCCESS)
        assert(inv.items.getStatField(101, invStatFieldName) == 'Updated item')
        for row in dinv_db.handle:nrows('SELECT name FROM items WHERE obj_id=101') do
          assert(row.name == 'Updated item')
        end
        """)
    }

    @Test("Database rejection rolls a snapshot back in memory and SQLite")
    func databaseRollback() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.seed()
        await driver.lua("""
        assert(dinv_db.handle:exec([[CREATE TRIGGER reject_test BEFORE INSERT ON items
          WHEN NEW.obj_id=103 BEGIN SELECT RAISE(ABORT, 'injected write failure'); END]]) == sqlite3.OK)
        """)
        await driver.snapshot()
        await driver.receive(
            "{invdata}",
            "102,,First staged item,1,9,0,0,0",
            "103,,Rejected item,1,9,0,0,0",
            "{/invdata}"
        )
        await driver.advance(0.1)
        await driver.lua("""
        assert(testResult == DRL_RET_INTERNAL_ERROR)
        assert(inv.items.table[102] == nil); assert(inv.items.table[103] == nil)
        local count=0
        for row in dinv_db.handle:nrows('SELECT obj_id FROM items') do
          assert(tonumber(row.obj_id)==101); count=count+1
        end
        assert(count==1)
        """)
    }

    @Test("A full scan reaches synchronized only after all locations finish")
    func completeRefresh() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        driver.replies = [
            "eqdata": ["{eqdata}", "{/eqdata}"],
            "invdata": ["{invdata}", "{/invdata}"],
            "keyring data": ["{keyring}", "{/keyring}"]
        ]
        await driver.lua("""
        inv.config.table.isBuildExecuted = true
        assert(inv.items.refresh(0, invItemsRefreshLocAll) == DRL_RET_SUCCESS)
        assert(not inv.items.fullScanCompleted)
        """)
        await driver.advance(1)
        await driver.lua("""
        assert(inv.items.fullScanCompleted); assert(inv.state == invStateIdle)
        assert(next(inv.runtime.tasks) == nil); assert(inv.commands.active == nil)
        """)
        #expect(driver.sent.contains("eqdata"))
        #expect(driver.sent.contains("invdata"))
        #expect(driver.sent.contains("keyring data"))
    }

    @Test("The wire identification path completes through its parser and queue boundaries")
    func wireIdentification() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.seed()
        driver.replies["identify 101"] = [
            "| Keywords : test item |", "| Name : Wire item |", "| Id : 101 |"
        ]
        await driver.lua("""
        testResult = nil
        inv.runtime.start(function()
          local commands = {}
          assert(inv.items.identifyItem(101, 'identify', {}, commands) == DRL_RET_SUCCESS)
          testResult = dbot.execute.safe.blocking(commands, inv.items.identifyAtomicSetup,
            nil, inv.items.identifyAtomicCleanup, 10)
        end)
        """)
        await driver.advance(1)
        await driver.lua("""
        assert(testResult == DRL_RET_SUCCESS, tostring(testResult))
        assert(inv.items.getStatField(101, invStatFieldName) == 'Wire item')
        assert(inv.items.identifyPkg == nil)
        """)
        #expect(driver.sent.filter { $0 == "identify 101" }.count == 1)
    }

    @Test("A conflicting raw request aborts capture and fences the following snapshot")
    func rawSnapshotInterference() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.snapshot()
        await driver.receive("{invdata}", "103,,Interrupted item,1,9,0,0,0")
        await driver.send("invdata")
        await driver.receive("{/invdata}", "{invdata}", "104,,Manual item,1,9,0,0,0", "{/invdata}")
        await driver.advance(0.1)
        await driver.lua("assert(testResult == DRL_RET_BUSY); assert(inv.items.table[103] == nil)")
        await driver.snapshot()
        await driver.receive("{invdata}", "105,,Fresh item,1,9,0,0,0", "{/invdata}")
        await driver.advance(0.1)
        await driver.lua("""
        assert(testResult == DRL_RET_SUCCESS); assert(inv.items.table[104] == nil)
        assert(inv.items.table[105])
        """)
    }

    @Test("MUSHclient's nonrecursive send hook leaves no stale bypass exemption")
    func mushclientSendHook() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.lua("""
        local host, send = proteles, SendNoEcho
        proteles = false
        local count = 0
        SendNoEcho = function(command) assert(command == 'look'); count=count+1; return 0 end
        assert(OnPluginSend('DINV_BYPASS look') == false)
        proteles, SendNoEcho = host, send
        assert(count == 1); assert(next(inv.commands.outbound) == nil)
        """)
    }

    @Test("Disconnect discards pending capture and reconnect loads the saved database")
    func reconnect() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.seed()
        await driver.snapshot()
        await driver.receive("{invdata}", "103,,Interrupted item,1,9,0,0,0")
        await driver.lua(#"""
        OnPluginTelnetSubnegotiation(201, 'config {"prompt":"YES"}')
        OnPluginDisconnect()
        assert(not inv.init.initializedActive)
        """#)
        await driver.advance(31)
        await driver.lua("OnPluginConnect()")
        await driver.boot()
        await driver.lua("""
        assert(inv.items.table[103] == nil)
        assert(inv.items.getStatField(101, invStatFieldName) == 'Saved item')
        assert(dbot.prompt.isEnabled == nil)
        assert(not inv.items.fullScanCompleted)
        """)
    }

    @Test("Malformed rows abort a snapshot without publishing or pruning")
    func malformedSnapshot() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.seed()
        await driver.snapshot()
        await driver.receive("{invdata}", "103,truncated", "{/invdata}")
        await driver.advance(0.1)
        await driver.lua("""
        assert(testResult == DRL_RET_INVALID_PARAM, tostring(testResult))
        assert(inv.items.table[103] == nil); assert(inv.items.table[101])
        """)
    }

    @Test("A queued timeout cannot disable another request's active parser")
    func parserOwnership() async throws {
        let driver = try await DinvCoordinatorDriver()
        await driver.boot()
        await driver.stopBackground()
        await driver.lua("""
        local enable = EnableTrigger
        testGetEnabled = false
        EnableTrigger = function(name, enabled)
          if name == inv.items.trigger.getName then testGetEnabled = enabled end
          return enable(name, enabled)
        end
        local result = {}
        inv.commands.enqueue({'test-active'}, inv.items.getSetupFn, nil,
          inv.items.getResultFn, result, {framed=true, timeout=30})
        testQueued = {}
        inv.commands.enqueue({'test-expired'}, inv.items.getSetupFn, nil,
          inv.items.getResultFn, testQueued, {framed=true, timeout=0.5})
        """)
        await driver.advance(1)
        await driver.lua("""
        assert(testQueued.retval == DRL_RET_TIMEOUT)
        assert(testGetEnabled, 'queued cleanup disabled the active parser')
        inv.commands.complete(inv.commands.active, DRL_RET_SUCCESS)
        assert(not testGetEnabled)
        """)
    }
}
