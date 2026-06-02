import Foundation
@testable import MudCore
import Testing

/// Regression for the live portal failure: dinv defers its portal cleanup with
/// `DoAfterSpecial(0.5, "wear <id> portal;put <id> <bag>", sendto.execute)`,
/// expecting the client to split the command-stacked string on `;` (MUSHclient
/// command stacking, which only applies on the `Execute` path). We previously
/// routed every non-script `DoAfterSpecial` as a *raw* send, so Aardwolf got the
/// whole `wear … portal;put …` line and reported "no 'portal;put …' wear
/// location". `sendto.execute` must instead run through the command pipeline,
/// where `;` is split into separate commands.
@Suite("SessionController — DoAfterSpecial sendto.execute", .serialized)
struct DoAfterSpecialExecuteTests {
    private let plugin = """
    <muclient>
    <plugin id="com.test.stackexec" name="StackExec"/>
    <script><![CDATA[
    function fire()
      DoAfterSpecial(0.05, "wear ABC portal;put DEF BAG", sendto.execute)
    end
    ]]></script>
    <aliases>
      <alias match="fire" enabled="y" script="fire" send_to="12"/>
    </aliases>
    </muclient>
    """

    @Test("A sendto.execute DoAfterSpecial splits a `;`-stacked command into separate sends")
    func executeSplitsCommandStack() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("fire")

        // The deferred Execute fires after 0.05s and must split on `;`. Poll
        // with a generous deadline: the firing rides the SessionController's
        // background timer loop, which can be starved for several seconds under
        // `swift test --parallel` on a contended CI runner. A long ceiling costs
        // wall-clock only if the action never fires (a real failure); on success
        // the loop breaks the instant the command lands.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if conn.sentLines.contains("put DEF BAG") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            conn.sentLines.contains("wear ABC portal"),
            "first stacked command missing/merged: \(conn.sentLines)"
        )
        #expect(
            conn.sentLines.contains("put DEF BAG"),
            "second stacked command was lost (not split on `;`): \(conn.sentLines)"
        )
        #expect(
            !conn.sentLines.contains("wear ABC portal;put DEF BAG"),
            "command stack `;` was sent whole instead of split: \(conn.sentLines)"
        )
        await controller.disconnect()
    }
}
