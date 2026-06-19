import Foundation

/// MUSHclient `Simulate`: feed text back through the inbound pipeline as if it
/// had arrived from the MUD. Used by the shim's `Simulate(...)`, S&D's `xtest`
/// harness, and the `notes` header. Factored out of `+Scripting` for the file
/// budget.
extension SessionController {
    /// Re-inject `text`: parse it into styled lines (see ``simulatedLines(from:)``)
    /// and run each through the normal line path, so triggers (user + S&D)
    /// process it and it displays — in colour, with codes stripped.
    func reinjectSimulated(_ text: String) async {
        for line in Self.simulatedLines(from: text) {
            await appendLineThroughScripts(line)
        }
    }

    /// Parse simulated `text` into styled ``Line``s the *same* way real inbound
    /// MUD bytes are parsed — ``ANSIParser`` → ``LineBuilder``. So embedded ANSI
    /// codes become styled runs (the line renders in colour) and `Line.text` is
    /// the *stripped* text (triggers match what they'd see from the MUD), rather
    /// than a raw line carrying literal escape codes. Newlines drive line
    /// finalisation (a lone trailing newline adds no spurious empty line),
    /// matching the live pipeline.
    static func simulatedLines(from text: String) -> [Line] {
        var parser = ANSIParser()
        var builder = LineBuilder()
        var lines: [Line] = []
        parser.process(Array(text.utf8)) { event in
            builder.consume(event) { lines.append($0) }
        }
        parser.flush { event in
            builder.consume(event) { lines.append($0) }
        }
        builder.flush { lines.append($0) }
        return lines
    }
}
