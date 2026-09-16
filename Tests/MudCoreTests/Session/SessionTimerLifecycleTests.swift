import Foundation
@testable import MudCore
import Testing

@Suite("Session timers — lifecycle boundaries", .serialized)
struct SessionTimerLifecycleTests {
    @Test("An unload takes effect before the next due plugin timer runs")
    func unloadBeforePendingSend() async throws {
        let engine = try ScriptEngine()
        let connection = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { connection })
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        await session.stopLifecycleTestClock()
        let plugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.test.timer-owner" name="Timer Owner"/>
        <script><![CDATA[
        function OnPluginInstall()
          DoAfterSpecial(60, "SendNoEcho('obsolete-owned-send')", sendto.script)
        end
        ]]></script></muclient>
        """)
        await engine.loadPlugin(plugin)
        let now = Date()
        try await engine.addTimer(MudTimer(schedule: .after(30), action: .script(
            "UnloadPlugin('com.test.timer-owner')"
        )), now: now)
        try await engine.addTimer(MudTimer(schedule: .after(70), action: .send("unrelated-send")), now: now)

        // A delayed host wake makes both callbacks due together. The old host
        // collected the plugin's send before applying the earlier unload.
        await session.applyDueTimers(at: now.addingTimeInterval(120))
        await session.stopLifecycleTestClock()
        #expect(!connection.sentLines.contains("obsolete-owned-send"))
        #expect(connection.sentLines.filter { $0 == "unrelated-send" }.count == 1)
        await session.disconnect()
    }

    @Test("Reload/cancel stops old dinv work and admits a fresh snapshot", arguments: ["reload", "cancel"])
    func dinvReloadBeforePendingSend(action: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dinv-reload-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ScriptEngine()
        await engine.setSQLiteDirectory(directory.path)
        let connection = InMemoryConnection()
        let session = SessionController(scriptEngine: engine, makeConnection: { connection })
        try await session.connect(to: .init(host: "test.invalid", port: 23))
        await session.dispatchGMCP(GMCPMessage(package: "char.status", json: #"{"level":150,"state":3}"#))
        await session.dispatchGMCP(GMCPMessage(
            package: "char.base",
            json: #"{"name":"Tester","class":"Mage"}"#
        ))
        await session.armBundledDinv(stateDirectory: directory.path)
        await session.loadPendingDinv()
        await session.stopLifecycleTestClock()
        await startInterruptedSnapshot(engine: engine, session: session)
        #expect(connection.sentLines.contains("invdata"))
        let now = Date()
        let control = action == "reload"
            ? "ReloadPlugin('\(DinvAssets.pluginID)')" : "Execute('dinv cancel')"
        try await engine.addTimer(MudTimer(schedule: .after(10), action: .script(control)), now: now)
        try await engine.addTimer(MudTimer(schedule: .after(70), action: .send("look")), now: now)

        await session.applyDueTimers(at: now.addingTimeInterval(120))
        await session.stopLifecycleTestClock()
        #expect(!connection.sentLines.contains("invdata 101"))
        #expect(connection.sentLines.filter { $0 == "look" }.count == 1)
        await session.applyScriptEffects(engine.process(line: "{/invdata}").effects)
        await verifyFreshSnapshot(engine: engine, session: session, connection: connection)
        #expect(connection.sentLines.filter { $0 == "invdata" }.count == 2)
        await session.disconnect()
    }

    private func startInterruptedSnapshot(engine: ScriptEngine, session: SessionController) async {
        let source = """
        assert(inv.init.initializedActive)
        inv.runtime.cancelAll(DRL_RET_HALTED)
        inv.config.table.refreshPeriod = 0
        inv.items.new(101)
        inv.items.setField(101, invFieldObjLoc, invItemLocInventory)
        inv.items.setField(101, invFieldIdentifyLevel, invIdLevelFull)
        inv.items.setStatField(101, invStatFieldId, 101)
        inv.items.setStatField(101, invStatFieldName, 'Saved item')
        inv.items.setStatField(101, invStatFieldStr, 17)
        assert(dinv_db.saveItem(101, inv.items.table[101]) == DRL_RET_SUCCESS)
        inv.runtime.start(function()
          inv.runtime.sleep(60)
          inv.commands.send('invdata 101')
        end)
        inv.runtime.start(function() inv.items.discoverLocation(invItemLocInventory) end)
        """
        await run(source, engine: engine, session: session)
        await session.applyDueTimers(at: Date().addingTimeInterval(0.1))
        await session.stopLifecycleTestClock()
        for line in ["{invdata}", "102,,Unfinished item,1,9,0,0,0"] {
            await session.applyScriptEffects(engine.process(line: line).effects)
        }
    }

    private func verifyFreshSnapshot(
        engine: ScriptEngine,
        session: SessionController,
        connection: InMemoryConnection
    ) async {
        let source = """
        assert(inv.init.initializedActive)
        assert(inv.items.getStatField(101, invStatFieldName) == 'Saved item')
        assert(inv.items.getStatField(101, invStatFieldStr) == 17)
        assert(inv.items.table[102] == nil)
        for row in dinv_db.handle:nrows('SELECT obj_id FROM items WHERE obj_id=102') do
          error('Unfinished snapshot was published')
        end
        assert(inv.commands.active == nil); assert(#inv.commands.queue == 0)
        assert(next(inv.runtime.tasks) == nil)
        inv.runtime.cancelAll(DRL_RET_HALTED)
        inv.runtime.start(function()
          testSnapshotResult = inv.items.discoverLocation(invItemLocInventory)
        end)
        """
        await run(source, engine: engine, session: session)
        var answered = connection.sentLines.count
        for _ in 0..<5 {
            await session.applyDueTimers(at: Date().addingTimeInterval(0.1))
            await session.stopLifecycleTestClock()
            let outgoing = Array(connection.sentLines.dropFirst(answered))
            answered += outgoing.count
            for command in outgoing {
                let replies: [String]
                if command.hasPrefix("echo ") {
                    replies = [String(command.dropFirst(5))]
                } else if command == "invdata" {
                    replies = ["{invdata}", "103,,Fresh item,1,9,0,0,0", "{/invdata}"]
                } else {
                    Issue.record("Unexpected fresh snapshot command: \(command)")
                    replies = []
                }
                for reply in replies {
                    await session.applyScriptEffects(engine.process(line: reply).effects)
                }
            }
        }
        let verification = """
        assert(testSnapshotResult == DRL_RET_SUCCESS, tostring(testSnapshotResult))
        assert(inv.items.table[103]); assert(inv.items.table[102] == nil)
        assert(inv.commands.active == nil); assert(next(inv.runtime.tasks) == nil)
        """
        await run(verification, engine: engine, session: session)
    }

    private func run(_ source: String, engine: ScriptEngine, session: SessionController) async {
        let raw = await engine.runInPluginEnvironment(DinvAssets.pluginID, source)
        for effect in raw {
            if case .note(let text, let foreground, _) = effect {
                #expect(foreground != "red", "Lua error: \(text)")
            }
        }
        await session.applyScriptEffects(engine.consumeRegistrations(raw, owner: DinvAssets.pluginID))
    }
}

private extension SessionController {
    /// Tests advance the actual timer engine explicitly, without a competing
    /// wall-clock task. No Lua timer or send functions are substituted.
    func stopLifecycleTestClock() {
        timerTask?.cancel()
        timerTask = nil
    }
}
