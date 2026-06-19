import Foundation

public extension ScriptEngine {
    /// Append one displayed line to the runtime's output-buffer mirror, backing
    /// the MUSHclient `GetLineCount`/`GetLineInfo`/… world functions. Called by
    /// `SessionController` per displayed line (post-gag).
    func recordOutputLine(
        id: UInt64, timestamp: Date, text: String, runs: [StyledRun], kind: OutputLineKind
    ) async {
        await runtime.recordOutputLine(id: id, timestamp: timestamp, text: text, runs: runs, kind: kind)
    }

    /// Clear the mirror and stamp the connect time (the buffer counts from
    /// connect). Called on each successful connect.
    func resetOutputBuffer(connectedAt: Date) async {
        await runtime.resetOutputBuffer(connectedAt: connectedAt)
    }
}
