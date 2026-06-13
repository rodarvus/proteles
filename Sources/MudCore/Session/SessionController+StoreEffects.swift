import Foundation

extension SessionController {
    /// Effects that just feed a UI store (the captured maps, the Consider list,
    /// the tick anchor, the Lua Console). Returns true when handled. Split out of
    /// `SessionController+Scripting` to keep that file within the line budget.
    func applyStoreEffect(_ effect: ScriptEffect) async -> Bool {
        switch effect {
        case .updateMap(let map):
            await mapStore.update(map)
        case .updateConsider(let snapshot):
            publishedConsiderContinuation.yield(snapshot)
        case .updateBigmap(let zone, let name, let lines):
            await bigmapStore.update(BigmapStore.ContinentMap(zone: zone, name: name, lines: lines))
        case .diagnostic(let source, let message):
            // Tee to the Lua Console window — and ALWAYS to the transcript
            // (#63): with #16 routing errors console-only, the red note never
            // exists, the console dies with the session, and a post-mortem
            // transcript had no record that a script failed.
            logTranscript(.note, "[script-error\(source.map { ": \($0)" } ?? "")] \(message)")
            await scriptDiagnostics.append(ScriptDiagnostic(
                severity: .error, source: source, message: message
            ))
        case .updateTick(let date):
            await gmcpState.setLastTick(date)
        default:
            return false
        }
        return true
    }
}
