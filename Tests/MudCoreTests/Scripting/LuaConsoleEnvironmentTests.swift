import Foundation
@testable import MudCore
import Testing

/// The Lua Console's environment picker + plugin-attributed diagnostics
/// (the console window's MudCore plumbing).
@Suite("Lua Console — plugin environments + diagnostics")
struct LuaConsoleEnvironmentTests {
    private let probePlugin = """
    <muclient>
    <plugin id="aaaaaaaaaaaaaaaaaaaaaaaa" name="Probe"/>
    <script><![CDATA[
    secret_value = 41
    ]]></script>
    </muclient>
    """

    private func noteTexts(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { if case .note(let text, _, _) = $0 { text } else { nil } }
    }

    @Test("console code can run inside a loaded plugin's sandbox env")
    func pluginEnvironment() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: probePlugin))

        // The plugin's global is invisible from the user environment…
        let user = await engine.evaluateConsole("secret_value")
        #expect(noteTexts(user) == ["lua: = nil"])
        // …but visible (and writable) from inside its environment.
        let inside = await engine.evaluateConsole(
            "secret_value + 1", inPlugin: "aaaaaaaaaaaaaaaaaaaaaaaa"
        )
        #expect(noteTexts(inside) == ["lua: = 42"])
        // An unknown environment is a console error, not a crash.
        let unknown = await engine.evaluateConsole("1", inPlugin: "ffffffffffffffffffffffff")
        #expect(noteTexts(unknown).first?.contains("no loaded plugin environment") == true)
    }

    @Test("the picker lists loaded plugins by display name")
    func environmentList() async throws {
        let engine = try ScriptEngine()
        #expect(await engine.consoleEnvironments().isEmpty)
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: probePlugin))
        let environments = await engine.consoleEnvironments()
        #expect(environments == [
            ScriptEngine.ConsoleEnvironment(id: "aaaaaaaaaaaaaaaaaaaaaaaa", name: "Probe")
        ])
    }

    @Test("a plugin script error emits a plugin-attributed diagnostic beside the red note")
    func errorDiagnostic() async throws {
        let crashing = """
        <muclient>
        <plugin id="bbbbbbbbbbbbbbbbbbbbbbbb" name="Crashy"/>
        <aliases>
        <alias match="^boom$" enabled="y" regexp="y" send_to="12" script="go_boom"/>
        </aliases>
        <script><![CDATA[
        function go_boom() error("kapow") end
        ]]></script>
        </muclient>
        """
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: crashing))
        let effects = await engine.expandInput("boom")
        let diagnostics = effects.compactMap { effect -> (String?, String)? in
            if case .diagnostic(let source, let message) = effect { (source, message) } else { nil }
        }
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.0 == "Crashy")
        #expect(diagnostics.first?.1.contains("kapow") == true)
        // The red scrollback note is still there (the console is a tee).
        #expect(noteTexts(effects).contains { $0.contains("kapow") })
    }
}
