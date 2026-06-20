import Foundation
@testable import MudCore
import Testing

/// `Tell`/`ColourTell` buffer coloured cells and only flush on `Note`/`ColourNote`.
/// MUSHclient also breaks the line on an embedded `"\n"`, so a plugin that builds
/// a table with `ColourTell` and ends on `ColourTell("…\n")` — a very common
/// "print my list" idiom — renders each row. Without newline-aware flushing the
/// whole table stayed buffered and never appeared (it only surfaced later,
/// prepended to the next `ColourNote`). Each test fails without that handling.
@Suite("Compat shim — ColourTell newline flushing")
struct ColourTellNewlineTests {
    /// The concatenated text of each emitted line (colourNote or echo), in order.
    private func lines(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { effect in
            switch effect {
            case .colourNote(let segments): segments.map(\.text).joined()
            case .echo(let text): text
            default: nil
            }
        }
    }

    @Test("ColourTell emits a line at each embedded newline (table idiom renders)")
    func colourTellSplitsOnNewline() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        // A two-row table built entirely with ColourTell, ending on "\n" with no
        // terminating Note — the shape of a plugin's "list" command.
        let effects = try await lua.run("""
        ColourTell("white", "", "a")
        ColourTell("cyan", "", "b")
        ColourTell("", "", "\\n")
        ColourTell("white", "", "c")
        ColourTell("", "", "\\n")
        """)
        #expect(lines(effects) == ["ab", "c"])
    }

    @Test("Tell honours an embedded newline, then a Note terminates the last line")
    func tellSplitsOnNewline() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("""
        Tell("line1\\nline2")
        Note("line3")
        """)
        #expect(lines(effects) == ["line1", "line2line3"])
    }
}
