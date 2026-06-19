import Foundation

extension LuaRuntime {
    /// Retain a compiled chunk's source (chunk name → source) so a later runtime
    /// error in it can show the offending line. Module-internal; called at the
    /// `=name` load sites (plugin scripts, `require`'d modules).
    nonisolated func rememberChunkSource(_ name: String, _ source: String) {
        chunkSources[name] = source
    }

    /// Coloured source-context lines for a Lua error/traceback whose topmost
    /// frame names a chunk we have source for: the offending line highlighted
    /// (black-on-white with an orange gutter), its neighbours dimmed (orange
    /// gutter, silver text) — matching Sath's `traceback_context`. Empty when no
    /// frame names a chunk we retained (a console one-liner, an unknown chunk).
    nonisolated func sourceContextEffects(forError message: String) -> [ScriptEffect] {
        guard let frame = LuaSourceContext.topFrame(in: message, knownChunks: Set(chunkSources.keys)),
              let source = chunkSources[frame.chunk],
              let window = LuaSourceContext.window(source: source, line: frame.line)
        else { return [] }
        return window.map { line in
            let gutter = String(format: "%4d: ", line.number)
            if line.isError {
                return .colourNote([
                    NoteSegment(text: gutter, foreground: "black", background: "#E04000"),
                    NoteSegment(text: line.text, foreground: "black", background: "white")
                ])
            }
            return .colourNote([
                NoteSegment(text: gutter, foreground: "#E04000"),
                NoteSegment(text: line.text, foreground: "silver")
            ])
        }
    }
}
