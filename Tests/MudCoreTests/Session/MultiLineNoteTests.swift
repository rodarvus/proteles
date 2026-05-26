import Foundation
@testable import MudCore
import Testing

/// Regression for the live "dinv priority display renders as one run-together
/// line" defect. dinv builds multi-line output (its priority table) as a single
/// `\n`-joined string and prints it in ONE `dbot.print` → `AnsiNote` call.
/// MUSHclient renders embedded `\n` inside a Note as line breaks; we appended
/// the whole block as a single scrollback line, so it collapsed. Output effects
/// now split on `\n`.
@Suite("SessionController — multi-line Note splitting", .serialized)
struct MultiLineNoteTests {
    private let plugin = """
    <muclient>
    <plugin id="com.test.multiline" name="MultiLine"/>
    <script><![CDATA[
    function blockNote() Note("alpha\\nbeta\\ngamma\\n") end
    ]]></script>
    <aliases>
      <alias match="blocknote" enabled="y" script="blockNote" send_to="12"/>
    </aliases>
    </muclient>
    """

    @Test("A Note with embedded newlines becomes separate scrollback lines")
    func multiLineNoteSplits() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin))
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("blocknote")

        let texts = await controller.scrollbackStore.snapshot().map(\.text)
        // The three lines must appear as distinct entries (trailing \n adds no
        // spurious empty line), not one collapsed "alpha\nbeta\ngamma".
        #expect(texts.contains("alpha"), "missing 'alpha' as its own line: \(texts)")
        #expect(texts.contains("beta"), "missing 'beta' as its own line: \(texts)")
        #expect(texts.contains("gamma"), "missing 'gamma' as its own line: \(texts)")
        #expect(
            !texts.contains(where: { $0.contains("\n") }),
            "an output line still contains an embedded newline: \(texts)"
        )
        await controller.disconnect()
    }
}
