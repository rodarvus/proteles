import Foundation
@testable import MudCore
import Testing

/// #29 end-to-end: a plugin's `SetTriggerOption(name, "omit_from_output", "y")`
/// must actually flip the gag on an **XML-plugin-defined** trigger at runtime —
/// the real shape of Galaban's exit plugin, which toggles omit_from_output on
/// its `PartroxisExitTrigger*` between movement bursts. The earlier shim-only
/// rebuild couldn't reach XML triggers (no shim spec); the host-level mutation
/// resolves the trigger by name on the engine, so it does.
@Suite("SetTriggerOption — runtime option mutation (#29)")
struct SetTriggerOptionTests {
    /// ExitTrig is XML-defined and starts ungagged. "ARM"/"DISARM" are XML
    /// triggers whose script toggles ExitTrig's omit_from_output at runtime.
    private let plugin = """
    <muclient>
    <plugin id="com.test.setoption" name="SetOption"/>
    <triggers>
      <trigger name="ExitTrig" enabled="y" regexp="y" match="^secret exit$"
               sequence="50" send_to="12"><send></send></trigger>
      <trigger regexp="y" match="^ARM$" send_to="12">
        <send>SetTriggerOption("ExitTrig", "omit_from_output", "y")</send></trigger>
      <trigger regexp="y" match="^DISARM$" send_to="12">
        <send>SetTriggerOption("ExitTrig", "omit_from_output", "n")</send></trigger>
    </triggers>
    </muclient>
    """

    @Test("SetTriggerOption omit_from_output toggles an XML trigger's gag at runtime")
    func togglesGagOnXMLTrigger() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))

        // Starts ungagged (omit_from_output defaults off).
        #expect(await engine.process(line: "secret exit").gag == false)

        // A fired trigger calls SetTriggerOption("...","omit_from_output","y").
        _ = await engine.process(line: "ARM")
        #expect(await engine.process(line: "secret exit").gag == true)

        // And back off — proving "n" clears it too.
        _ = await engine.process(line: "DISARM")
        #expect(await engine.process(line: "secret exit").gag == false)
    }
}
