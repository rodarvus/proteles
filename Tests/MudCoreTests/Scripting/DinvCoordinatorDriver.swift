import Foundation
@testable import MudCore
import Testing

/// Deterministic wire/clock driver for the real bundled dinv scripts.
final class DinvCoordinatorDriver {
    let engine: ScriptEngine
    let directory: URL
    var sent: [String] = []
    var notes: [String] = []
    var incoming: [String] = []
    var replies: [String: [String]] = [:]
    var echoes = true
    var now = 0.0

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dinv-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engine = try ScriptEngine()
        await engine.registerModules(DinvAssets.modules)
        await engine.setSQLiteDirectory(directory.path)
        let path = directory.path + "/"
        let context = PluginContext(
            pluginID: DinvAssets.pluginID,
            pluginName: "dinv",
            version: "3.0127",
            pluginDirectory: path,
            worldDirectory: path,
            appDirectory: path,
            stateDirectory: path
        )
        let plugin = try MUSHclientPluginLoader.parse(xml: #require(DinvAssets.pluginXML))
        await apply(engine.loadPlugin(plugin, context: context))
        // Timer registrations normally use wall time. Substitute only the clock
        // so late replies and queue deadlines can be replayed without sleeping.
        await lua("""
        testNow = 0; testTimers = {}; testSequence = 0
        inv.runtime.now = function() return testNow end
        AddTimer = function(name, hours, minutes, seconds, send, flags, callback)
          testSequence = testSequence + 1
          testTimers[name] = {at=testNow+hours*3600+minutes*60+seconds,
                             callback=callback, seq=testSequence}
          return 0
        end
        local hostDeleteTimer = DeleteTimer
        DeleteTimer = function(name)
          testTimers[name] = nil
          return hostDeleteTimer(name)
        end
        """)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func apply(_ effects: [ScriptEffect]) async {
        for effect in effects {
            switch effect {
            case .send(let command), .sendNoEcho(let command): await send(command)
            case .execute(let command): await apply(engine.expandInput(command))
            case .note(let text, let foreground, _):
                notes.append(text)
                #expect(foreground != "red", "Lua error: \(text)")
            case .echoAnsi(let text), .echoAard(let text): notes.append(text)
            case .colourNote(let segments): notes.append(segments.map(\.text).joined())
            default: break
            }
        }
    }

    func send(_ command: String) async {
        let (blocked, effects) = await engine.fireOnPluginSend(command)
        await apply(effects)
        if !blocked {
            sent.append(command)
            incoming += replies[command] ?? []
            if echoes, command.hasPrefix("echo ") {
                incoming.append(String(command.dropFirst(5)))
            }
        }
    }

    func lua(_ source: String) async {
        let effects = await engine.runInPluginEnvironment(DinvAssets.pluginID, source)
        await apply(engine.consumeRegistrations(effects, owner: DinvAssets.pluginID))
    }

    func receive(_ lines: String...) async {
        for line in lines {
            await apply(engine.process(line: line).effects)
        }
    }

    func boot() async {
        await apply(engine.applyGMCP(package: "char.status", json: #"{"level":150,"state":3}"#))
        await lua("assert(not inv.init.initializedActive); assert(dinv_db.handle == nil)")
        await apply(engine.applyGMCP(
            package: "char.base",
            json: #"{"name":"Tester","class":"Mage","subclass":"Sorcerer"}"#
        ))
        await lua("assert(inv.init.initializedActive); assert(dinv_db.handle)")
    }

    func advance(_ seconds: Double) async {
        now += seconds
        for _ in 0..<2000 {
            while !incoming.isEmpty {
                let line = incoming.removeFirst()
                await receive(line)
            }
            let priorCount = notes.count
            await lua("""
            local name, timer
            for n, t in pairs(testTimers) do
              if t.at <= \(now) and (not timer or t.at < timer.at or
                  (t.at == timer.at and t.seq < timer.seq)) then name, timer = n, t end
            end
            if timer then
              testTimers[name] = nil; testNow = timer.at
              local fn = assert(loadstring(timer.callback .. '("' .. name .. '")'))
              fn()
            else testNow = \(now); proteles.note('TEST_QUIET') end
            """)
            if notes.dropFirst(priorCount).contains("TEST_QUIET") {
                return
            }
        }
        Issue.record("Clock did not quiesce")
    }

    func stopBackground() async {
        await lua("""
        inv.runtime.cancelAll(DRL_RET_HALTED)
        inv.config.table.refreshPeriod = 0
        """)
    }

    func seed() async {
        await lua("""
        inv.items.new(101)
        inv.items.setField(101, invFieldObjLoc, invItemLocInventory)
        inv.items.setField(101, invFieldIdentifyLevel, invIdLevelFull)
        inv.items.setStatField(101, invStatFieldId, 101)
        inv.items.setStatField(101, invStatFieldName, 'Saved item')
        inv.items.setStatField(101, invStatFieldStr, 17)
        assert(dinv_db.saveItem(101, inv.items.table[101]) == DRL_RET_SUCCESS)
        """)
    }

    func snapshot() async {
        await lua("""
        testResult = nil
        inv.runtime.start(function()
          testResult = inv.items.discoverLocation(invItemLocInventory)
        end)
        """)
        await advance(0.2)
        #expect(sent.contains("invdata"))
    }
}
