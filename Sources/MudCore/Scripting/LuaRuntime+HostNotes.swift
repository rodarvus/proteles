extension LuaRuntime {
    /// Build `ColourNote` segments from its variadic `(fore, back, text)`
    /// triples. An empty colour string means "default" -> `nil`. Trailing
    /// partial triples (missing text) are ignored, matching MUSHclient.
    nonisolated static func noteSegments(_ arguments: [LuaValue]) -> [NoteSegment] {
        var segments: [NoteSegment] = []
        var index = 0
        while index + 3 <= arguments.count {
            let fore = nonEmpty(arguments[index].stringValue)
            let back = nonEmpty(arguments[index + 1].stringValue)
            let text = arguments[index + 2].stringValue ?? ""
            segments.append(NoteSegment(text: text, foreground: fore, background: back))
            index += 3
        }
        return segments
    }

    /// Internal shim call used by `NoteStyle`: `(fore, back, text, style)` tuples.
    /// Kept separate from public `ColourNote` triples so valid multi-triple
    /// output can never be misparsed as styled output.
    nonisolated static func styledNoteSegments(_ arguments: [LuaValue]) -> [NoteSegment] {
        var segments: [NoteSegment] = []
        var index = 0
        while index + 4 <= arguments.count {
            let fore = nonEmpty(arguments[index].stringValue)
            let back = nonEmpty(arguments[index + 1].stringValue)
            let text = arguments[index + 2].stringValue ?? ""
            let style = Int(arguments[index + 3].numberValue ?? 0)
            segments.append(NoteSegment(text: text, foreground: fore, background: back, noteStyle: style))
            index += 4
        }
        return segments
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
