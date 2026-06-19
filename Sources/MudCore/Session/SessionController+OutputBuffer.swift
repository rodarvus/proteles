import Foundation

/// Feeding the script runtime's output-buffer mirror (the backing for the
/// MUSHclient `GetLineCount`/`GetLineInfo`/… world functions). Split from
/// `SessionController+Scripting` for the file-length budget.
public extension SessionController {
    /// Append a displayed line to scrollback **and** mirror it into the script
    /// runtime's output buffer, so the output-buffer world functions see it.
    /// `kind` (mud / note / user-input) backs the per-line note/user flags. Use
    /// this for every displayed line so the mirror matches what the user sees.
    func recordDisplayed(_ line: Line, kind: OutputLineKind) async {
        let id = await scrollbackStore.append(line)
        await scriptEngine?.recordOutputLine(
            id: id.raw, timestamp: line.timestamp, text: line.text, runs: line.runs, kind: kind
        )
    }
}
