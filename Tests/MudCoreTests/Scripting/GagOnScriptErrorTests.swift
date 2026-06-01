import Foundation
@testable import MudCore
import Testing

/// Does an omit-from-output trigger still gag its line when its script raises a
/// Lua error? (dinv's wish item trigger gags `^(.*)$` and runs
/// `dbot.wish.trigger.fn("%1")`; if that errors on a line the gag must still
/// hold — MUSHclient applies omit_from_output regardless of script outcome.)
@Suite("gag survives a trigger script error")
struct GagOnScriptErrorTests {
    @Test("an OmitFromOutput trigger whose script errors still gags the line")
    func gagSurvivesError() async throws {
        let engine = try ScriptEngine()
        // A plugin whose trigger gags every line but its script indexes a nil
        // global → a runtime Lua error (mirrors dbot.wish.table being nil).
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: """
        <muclient><plugin id="com.test.gagerr" name="GagErr"/>
        <script><![CDATA[
        function OnPluginInstall()
          AddTriggerEx("g", "^(.*)$", "boom.kaboom = true", 1 + 4 + 32, -1, 0, "", "", 12, 0)
        end
        ]]></script></muclient>
        """))
        let disposition = await engine.process(line: "a line that should be gagged")
        #expect(disposition.gag, "gag was dropped when the trigger script errored")
    }
}
