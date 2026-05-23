import Foundation

/// Native port of Aardwolf's `aard_note_mode` (Fiendish): while you're
/// writing an in-game note, pause every automation so your keystrokes and
/// the game's output reach the note unmodified, then resume when you finish.
///
/// Aardwolf signals note-writing with `char.status.state == 5`. This plugin
/// watches that transition (via ``onGMCP(package:json:)``) and emits
/// ``ScriptEffect/setAutomationsSuspended(_:)`` — the host then sends typed
/// input verbatim, lets incoming lines through, and stops firing timers. A
/// short coloured note marks each transition. No commands; no miniwindow.
public struct NoteMode: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.notemode",
        name: "Note Mode",
        author: "Proteles (after Fiendish)",
        version: "1.0",
        summary: "Pauses triggers, aliases, timers, and commands while you write an in-game note."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Automatically suspends all automations while Aardwolf reports you're "
                + "writing a note (char.status.state 5), and resumes them when you finish. "
                + "Runs by itself — there are no commands."
        )
    }

    /// Whether we currently believe note-writing is active, so we only act
    /// on transitions (not every char.status update).
    private var inNoteMode = false

    private struct StatusState: Decodable { let state: Int? }

    public init() {}

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        guard package.lowercased() == "char.status" else { return [] }
        let state = (try? JSONDecoder().decode(StatusState.self, from: Data(json.utf8)))?.state
        let writing = state == 5
        guard writing != inNoteMode else { return [] }
        inNoteMode = writing
        let message = writing ? "Note mode — automations paused." : "Note mode off — automations resumed."
        return [
            .setAutomationsSuspended(writing),
            .colourNote([NoteSegment(text: message, foreground: "#C0C0C0")])
        ]
    }
}
