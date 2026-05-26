import Foundation
@testable import MudCore
import Testing

/// Regression for the live "everything gagged after dinv set/analyze/priority
/// display" defect. dinv reads spell-stat bonuses with a catch-all gag trigger
/// (`^(.*)$`, OmitFromOutput) whose script body is `inv.statBonus.trigger.get("%1")`;
/// it disables itself when it sees its own closing marker `{ \dinv inv.statBonus }`.
/// Our trigger fire path `%`-substitutes the capture straight into that Lua
/// string literal, so a captured backslash produced `get("{ \dinv … }")` — and
/// Lua 5.1 rejects `\d` as an invalid escape. The script errored, never reached
/// `EnableTrigger(getName, false)`, and the `^(.*)$` gag stayed on → all output
/// suppressed. Captures must be escaped for the Lua string context.
@Suite("ScriptEngine — trigger script wildcard escaping", .serialized)
struct TriggerScriptWildcardEscapeTests {
    /// A plugin whose `^(.*)$` trigger records the captured line into a variable
    /// via a `%1`-substituted script body — mirroring dinv's statBonus capture.
    private let plugin = """
    <muclient>
    <plugin id="com.test.wcescape" name="WCEscape"/>
    <script><![CDATA[
    function record(line) SetVariable("captured", line) end
    ]]></script>
    <triggers>
      <trigger match="^(.*)$" enabled="y" regexp="y" omit_from_output="y"
               send_to="12" sequence="100">
        <send>record("%1")</send>
      </trigger>
    </triggers>
    </muclient>
    """

    @Test("A capture containing a backslash is escaped so the script body is valid Lua")
    func backslashCaptureDoesNotBreakScript() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))

        // The exact shape dinv echoes as its statBonus closing marker.
        let line = #"{ \dinv inv.statBonus }"#
        _ = await engine.process(line: line)

        let captured = await engine.variablesSnapshot()["com.test.wcescape"]?["captured"]
        #expect(
            captured == line,
            "trigger script body broke on a backslash capture (got \(captured ?? "nil"))"
        )
    }
}
