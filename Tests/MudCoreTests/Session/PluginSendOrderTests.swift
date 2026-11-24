import Foundation
@testable import MudCore
import Testing

/// Every send is offered to `OnPluginSend`, even while another task's send
/// is in the hook. MUSHclient skips the hook only for a send made *from
/// inside* it (its `m_bPluginProcessingSend`); a send from elsewhere waits
/// its turn. session-20261124-074839, 08:05:01: a second walk's markers,
/// sent while the first walk's segment was in dinv's hook, skipped dinv's
/// portal-hop hold and reached the MUD out of order.
@Suite("SessionController — OnPluginSend for every send", .serialized)
struct PluginSendOrderTests {
    /// Holds every line it's offered, as dinv does during a portal hop.
    private static let holder = """
    <muclient>
    <plugin id="com.test.holder" name="Holder" save_state="n"/>
    <script><![CDATA[
    held = {}
    function OnPluginSend(msg)
      table.insert(held, msg)
      return false
    end
    ]]></script>
    </muclient>
    """

    @Test("sends from two tasks at once are all offered to the hook, none bypass it")
    func concurrentSendsAllOffered() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: Self.holder))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))
        defer { Task { await controller.disconnect() } }
        let before = conn.sentLines
        async let first: Void = controller.applyScriptEffects(["a1", "a2", "a3"].map { .sendNoEcho($0) })
        async let second: Void = controller.applyScriptEffects(["b1", "b2", "b3"].map { .sendNoEcho($0) })
        _ = await (first, second)
        let leaked = conn.sentLines.dropFirst(before.count).filter { $0.count == 2 }
        #expect(leaked.isEmpty, "bypassed the hook: \(leaked)")
        let effects = await engine.runInPluginEnvironment("com.test.holder", "Send(table.concat(held, ','))")
        let held = effects.compactMap { effect -> String? in
            if case .send(let text) = effect { return text }
            return nil
        }.first ?? ""
        let order = held.split(separator: ",").map(String.init)
        #expect(Set(order) == ["a1", "a2", "a3", "b1", "b2", "b3"])
        // Each task's own lines keep their order.
        #expect(order.filter { $0.hasPrefix("a") } == ["a1", "a2", "a3"])
        #expect(order.filter { $0.hasPrefix("b") } == ["b1", "b2", "b3"])
    }
}
