import Foundation
@testable import MudCore
import Testing

/// The shim's `GetNormalColour`/`GetBoldColour` must be ONE-based like
/// MUSHclient (`methods_colours.cpp`: bounds 1..8, `[n-1]` lookup, out of
/// range → 0) — so 7 is **cyan** and 8 is white. A 0-based table made every
/// plugin colour guard fail silently: rsocials compares
/// `styles[1].textcolour` to `GetNormalColour(7)` before forwarding a social
/// to the chat-capture window, got *white* instead of cyan, and never
/// forwarded — nothing reached the Channels panel (live report, 2026-06-10).
///
/// This drives the real chain: trigger fires with `styles` → the plugin's
/// colour guard passes for a cyan/bright-magenta line → `CallPlugin(<chat
/// capture>, "storeFromOutside", …)` → the bridged `.chatCapture` effect.
@Suite("shim colour tables — 1-based like MUSHclient (rsocials guard)")
struct ShimColourTableTests {
    /// The rsocials guard, verbatim in shape: forward only when the line
    /// starts dark cyan (`GetNormalColour(7)`) or bright magenta
    /// (`GetBoldColour(6)`).
    private let guardPlugin = """
    <muclient>
    <plugin id="com.test.rsocial" name="RsocialGuard"/>
    <triggers>
    <trigger enabled="y" match="^\\*.+$" regexp="y" script="Process_Rsocial_Line" sequence="10"/>
    </triggers>
    <script><![CDATA[
    function Process_Rsocial_Line(name, line, wildcards, styles)
      if styles[1].textcolour == GetNormalColour(7)
         or styles[1].textcolour == GetBoldColour(6) then
        CallPlugin("b555825a4a5700c35fa80780", "storeFromOutside", line)
      end
    end
    ]]></script>
    </muclient>
    """

    private func process(_ engine: ScriptEngine, colour: ANSIColor) async -> ScriptEngine.LineDisposition {
        let text = "* Someone waves happily."
        let line = Line(id: LineID(1), text: text, runs: [
            StyledRun(
                utf16Range: 0..<text.utf16.count,
                style: StyleAttributes(foreground: colour)
            )
        ])
        return await engine.process(line)
    }

    @Test("a dark-cyan social passes the guard and reaches chat capture")
    func cyanForwards() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: guardPlugin))
        let disposition = await process(engine, colour: .named(.cyan))
        #expect(disposition.effects.contains(
            .chatCapture(text: "* Someone waves happily.", channel: "")
        ))
    }

    @Test("a bright-magenta social passes the guard too")
    func brightMagentaForwards() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: guardPlugin))
        let disposition = await process(engine, colour: .brightNamed(.magenta))
        #expect(disposition.effects.contains(
            .chatCapture(text: "* Someone waves happily.", channel: "")
        ))
    }

    @Test("a white line fails the guard — no forward (the guard works both ways)")
    func whiteDoesNotForward() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: guardPlugin))
        let disposition = await process(engine, colour: .named(.white))
        #expect(!disposition.effects.contains {
            if case .chatCapture = $0 { return true }
            return false
        })
    }
}
