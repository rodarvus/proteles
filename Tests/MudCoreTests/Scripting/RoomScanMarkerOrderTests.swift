import Foundation
@testable import MudCore
import Testing

/// The marker-scan plugin shape (live report, 2026-06-10): a start trigger on
/// `{roomchars}` arms a same-sequence catch-all `^(?P<char_line>.+)$`, and the
/// end trigger `*{/roomchars}*` disarms it and clears a `scanning` flag the
/// catch-all's handler gates on. Both the catch-all and the end trigger match
/// the `{/roomchars}` line; MUSHclient's same-sequence order (match text,
/// byte-wise — `*` < `^`) runs the end handler first, so the catch-all
/// self-gates. With insertion-order ties, an EMPTY block (`{roomchars}`
/// directly followed by `{/roomchars}` — every cleared room) captured the
/// closing tag itself as a "mob", and the kill loop attacked `{/roomchars}`.
@Suite("shim plugins — marker-scan trigger order")
struct RoomScanMarkerOrderTests {
    /// Generic stand-in for the reported plugin's roomscan: same sequences,
    /// same match shapes, same self-gating handler structure, defined in the
    /// same order (catch-all before end marker).
    private let scanPlugin = """
    <muclient>
    <plugin id="com.test.scanorder" name="ScanOrder"/>
    <triggers>
    <trigger match="{roomchars}" enabled="y" regexp="n" keep_evaluating="y"
       send_to="12" script="scan_start" sequence="40"></trigger>
    <trigger match="^(?P&lt;char_line&gt;.+)$" enabled="n" regexp="y" name="scan_chars"
       keep_evaluating="y" send_to="12" script="scan_char" sequence="40"></trigger>
    <trigger match="*{/roomchars}*" enabled="y" regexp="n" keep_evaluating="y"
       send_to="12" script="scan_end" sequence="40"></trigger>
    </triggers>
    <script><![CDATA[
    scanning = false
    seen = {}
    function scan_start(name, line, wildcards)
      scanning = true
      seen = {}
      EnableTrigger("scan_chars", true)
    end
    function scan_char(name, line, wildcards)
      if not scanning then return end
      table.insert(seen, wildcards.char_line or line)
    end
    function scan_end(name, line, wildcards)
      if not scanning then return end
      EnableTrigger("scan_chars", false)
      scanning = false
      Note("scan:" .. table.concat(seen, "|"))
    end
    ]]></script>
    </muclient>
    """

    /// The shim's `Note(...)` surfaces as an `.echo` effect.
    private func noteText(_ effects: [ScriptEffect]) -> String? {
        for effect in effects {
            if case .echo(let text) = effect { return text }
            if case .note(let text, _, _) = effect { return text }
        }
        return nil
    }

    /// Run lines through the engine, returning the scan summary the end
    /// marker's handler emits.
    private func scan(_ lines: [String]) async throws -> String? {
        let engine = try ScriptEngine()
        // The XML must arm the start/end triggers itself here (no kill command
        // flips the group on) — but the catch-all starts disabled, exactly
        // like the real plugin.
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: scanPlugin))
        var note: String?
        for line in lines {
            let disposition = await engine.process(line: line)
            if let text = noteText(disposition.effects) { note = text }
        }
        return note
    }

    @Test("an EMPTY block captures nothing — the closing tag is not a mob")
    func emptyBlock() async throws {
        let note = try await scan(["{roomchars}", "{/roomchars}"])
        #expect(note == "scan:")
    }

    @Test("a populated block captures the char lines, not the markers")
    func populatedBlock() async throws {
        let note = try await scan([
            "{roomchars}",
            "(R) A crab shaped like a spider is crawling back to the water.",
            "(R) A crab shaped like a spider is crawling back to the water.",
            "{/roomchars}"
        ])
        #expect(note == "scan:(R) A crab shaped like a spider is crawling back to the water."
            + "|(R) A crab shaped like a spider is crawling back to the water.")
    }

    @Test("the scan re-arms cleanly for a second look")
    func secondScan() async throws {
        let note = try await scan([
            "{roomchars}", "a fierce mob is here.", "{/roomchars}",
            "{roomchars}", "{/roomchars}"
        ])
        #expect(note == "scan:")
    }
}
