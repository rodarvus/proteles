import Foundation
@testable import MudCore
import Testing

/// `savePluginState()` — the app-termination hook: run every plugin's
/// `OnPluginSaveState` (in its own environment) and persist dirty variables
/// to the attached ``VariableStore``. Before this existed, state was only
/// saved on a clean disconnect, so quitting while connected lost anything
/// changed since connect (the live `ldb on` report, 2026-06-10).
@Suite("plugin state saves on app termination")
struct SavePluginStateTests {
    private let statefulPlugin = """
    <muclient>
    <plugin id="com.test.state" name="Stateful" save_state="y"/>
    <script><![CDATA[
    function OnPluginSaveState()
      SetVariable("captures", "on")
    end
    ]]></script>
    </muclient>
    """

    @Test("OnPluginSaveState runs and the variable reaches disk")
    func savesOnTermination() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-savestate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = try ScriptEngine()
        let session = SessionController(scriptEngine: engine)
        await session.attachVariableStore(VariableStore(url: url))
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: statefulPlugin))

        await session.savePluginState()

        let json = try String(decoding: Data(contentsOf: url), as: UTF8.self)
        #expect(json.contains("\"captures\""))
        #expect(json.contains("\"on\""))
    }
}
