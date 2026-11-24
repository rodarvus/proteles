import Foundation
@testable import MudCore
import Testing

/// The 999 "running" broadcast plugins hear (`kinda_busy` /
/// `ok_you_can_go_now`), driven by the real SessionController and Mapper.
@Suite("SessionController — running broadcast", .serialized)
struct RunningBroadcastTests {
    /// Records every 999 broadcast it hears.
    private static let listener = """
    <muclient>
    <plugin id="com.test.running" name="Running" save_state="n"/>
    <script><![CDATA[
    heard = {}
    function OnPluginBroadcast(msg, id, name, text)
      if msg == 999 then table.insert(heard, text) end
    end
    ]]></script>
    </muclient>
    """

    private struct Rig {
        let controller: SessionController
        let engine: ScriptEngine
        let conn: InMemoryConnection
    }

    private func makeSession(
        mapper: Mapper? = nil,
        native: (any NativePlugin)? = nil
    ) async throws -> Rig {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: Self.listener))
        if let native { _ = await engine.registerNativePlugin(native) }
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        if let mapper { await controller.attachMapper(mapper) }
        try await controller.connect(to: .init(host: "test.invalid", port: 23))
        return Rig(controller: controller, engine: engine, conn: conn)
    }

    private func heard(_ engine: ScriptEngine) async -> String {
        let script = "Send(table.concat(heard, ','))"
        let effects = await engine.runInPluginEnvironment("com.test.running", script)
        for case .send(let text) in effects {
            return text
        }
        return "?"
    }

    private func reflect(_ controller: SessionController, _ text: String) async {
        _ = await controller.handleWalkMarker(Line(id: LineID(0), text: text))
    }

    @Test("broadcasts only on a change, as the reference's sent_busy does")
    func onlyOnChange() async throws {
        let rig = try await makeSession()
        defer { Task { await rig.controller.disconnect() } }
        let (begin, end) = ("{begin running}", "{end running}")
        for text in [begin, begin, end, end, begin] {
            await reflect(rig.controller, text)
        }
        #expect(await heard(rig.engine) == "kinda_busy,ok_you_can_go_now,kinda_busy")
    }

    @Test("disconnecting mid-walk tells plugins the walk is over")
    func disconnectEnds() async throws {
        let rig = try await makeSession()
        await reflect(rig.controller, "{begin running}")
        await rig.controller.disconnect()
        // The disconnect callbacks run on a task of their own.
        for _ in 0..<100 where await heard(rig.engine) != "kinda_busy,ok_you_can_go_now" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await heard(rig.engine) == "kinda_busy,ok_you_can_go_now")
    }

    @Test("a failed move ends the walk on the wire and holds its next segment back")
    func failedMoveEndsWalk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let mapper = try Mapper(store: MapperStore(url: url))
        let start = #"{"num":1,"name":"Start","zone":"z","exits":{}}"#
        let portalDest = #"{"num":14,"name":"PortalDest","zone":"z","exits":{"s":20}}"#
        for json in [#"{"num":20,"name":"Target","zone":"z","exits":{}}"#, portalDest, start] {
            _ = await mapper.ingest(package: "room.info", json: json)
        }
        _ = await mapper.handleCommand("mapper fullportal {dinv portal use 999} {14}")
        _ = await mapper.ingest(package: "room.info", json: start)
        let rig = try await makeSession(mapper: mapper)
        let (controller, conn) = (rig.controller, rig.conn)
        defer { Task { await controller.disconnect() } }

        await controller.fire(.command("mapper goto 20"))
        #expect(conn.sentLines.contains(Mapper.beginRunningMarker))
        #expect(!conn.sentLines.contains(Mapper.endRunningMarker))
        // The line is from the recordings; it still displays.
        let failed = Line(id: LineID(0), text: "Alas, you cannot go that way.")
        let consumed = await controller.handleWalkMarker(failed)
        #expect(!consumed)
        #expect(conn.sentLines.filter { $0 == Mapper.endRunningMarker }.count == 1)
        await controller.dispatchGMCP(GMCPMessage(package: "room.info", json: portalDest))
        #expect(!conn.sentLines.contains("run s"))
    }

    @Test("native plugins hear the walk too: Consider holds its refresh until the walk ends")
    func nativePluginsHear() async throws {
        var consider = ConsiderFeature()
        _ = consider.handleCommand("conw on")
        let rig = try await makeSession(native: consider)
        let (controller, conn) = (rig.controller, rig.conn)
        defer { Task { await controller.disconnect() } }
        let room = { (num: Int) in
            GMCPMessage(package: "room.info", json: #"{"num":\#(num),"name":"r","zone":"z","details":""}"#)
        }
        let status = #"{"level":100,"state":3,"align":500}"#
        await controller.dispatchGMCP(GMCPMessage(package: "char.status", json: status))
        await controller.dispatchGMCP(room(1))
        let considers = { conn.sentLines.count { $0 == "consider all" } }
        #expect(considers() == 1)
        await reflect(controller, "{begin running}")
        await controller.dispatchGMCP(room(2))
        #expect(considers() == 1)
        await reflect(controller, "{end running}")
        #expect(considers() == 2)
    }
}
