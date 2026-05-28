import Foundation

public extension SessionController {
    /// Fire a macro's action. A `.command` runs through the same input
    /// pipeline as typed text (so aliases + `;`-stacking apply); a `.script`
    /// runs as Lua in the user script environment and its effects are applied.
    func fire(_ action: MacroAction) async {
        switch action {
        case .command(let command):
            try? await send(command)
        case .script(let script):
            guard let scriptEngine else { return }
            await applyScriptEffects(scriptEngine.run(script))
            await persistVariablesIfDirty()
            await rearmTimerLoopIfScriptScheduled()
        }
    }
}
