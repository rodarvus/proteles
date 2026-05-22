import Foundation

/// Applying scripting decisions (triggers/aliases) to the live session.
extension SessionController {
    /// Run a received line through the script engine (if any), then append
    /// it unless a trigger gagged it. Trigger sends/echoes are applied
    /// afterwards so echoes land just below the line that produced them.
    func appendLineThroughScripts(_ line: Line) async {
        guard let scriptEngine else {
            await scrollbackStore.append(line)
            return
        }
        let disposition = await scriptEngine.process(line: line.text)
        if !disposition.gag {
            await scrollbackStore.append(line)
        }
        await applyScriptEffects(disposition.effects)
    }

    /// Apply the effects a script produced: sends go to the MUD, echoes/notes
    /// to the scrollback.
    func applyScriptEffects(_ effects: [ScriptEffect]) async {
        for effect in effects {
            switch effect {
            case .send(let command), .execute(let command), .sendNoEcho(let command):
                try? await sendLine(command)
            case .echo(let text):
                await scrollbackStore.append(Line(id: LineID(0), text: text))
            case .note(let text, let foreground, let background):
                await scrollbackStore.append(Line(
                    id: LineID(0),
                    text: text,
                    runs: Self.noteRuns(text, foreground: foreground, background: background)
                ))
            }
        }
    }

    static func noteRuns(_ text: String, foreground: String?, background: String?) -> [StyledRun] {
        var style = StyleAttributes.default
        if let foreground, let color = namedColor(foreground) { style.foreground = color }
        if let background, let color = namedColor(background) { style.background = color }
        let length = (text as NSString).length
        guard !style.isDefault, length > 0 else { return [] }
        return [StyledRun(utf16Range: 0..<length, style: style)]
    }

    static func namedColor(_ name: String) -> ANSIColor? {
        let names: [String: NamedColor] = [
            "black": .black, "red": .red, "green": .green, "yellow": .yellow,
            "blue": .blue, "magenta": .magenta, "cyan": .cyan, "white": .white
        ]
        return names[name.lowercased()].map { .named($0) }
    }
}
