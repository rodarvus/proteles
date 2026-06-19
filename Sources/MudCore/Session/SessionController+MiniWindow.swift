import Foundation

/// Miniwindow effects + hotspot dispatch on the session (the miniwindow spike,
/// `docs/plans/MINIWINDOW_FEASIBILITY.md`). Split from `SessionController
/// +Scripting` for the file-length budget.
extension SessionController {
    /// Forward a miniwindow effect to the UI stream. Returns whether it handled
    /// `effect` (so ``applyControlEffect(_:)`` can early-return, keeping its
    /// switch within the complexity budget).
    func applyMiniWindowEffect(_ effect: ScriptEffect) -> Bool {
        PerformanceProbe.shared.measure(
            "session.miniwindow.effect",
            events: 1,
            thresholdMS: 100
        ) {
            switch effect {
            case .updateMiniWindow(let scene):
                miniWindowUpdatesContinuation.yield(.update(scene))
            case .deleteMiniWindow(let name):
                miniWindowUpdatesContinuation.yield(.delete(name: name))
            case .loadMiniWindowImage(let pluginID, let imageID, let data):
                miniWindowUpdatesContinuation.yield(.image(
                    pluginID: pluginID,
                    imageID: imageID,
                    data: data
                ))
            default:
                return false
            }
            return true
        }
    }

    /// Dispatch a miniwindow hotspot interaction (Phase 2): invoke the owning
    /// plugin's registered Lua callback with MUSHclient's `(flags, hotspotID)`
    /// arguments, then apply whatever effects it produced (sends, a window
    /// redraw, …). The UI calls this from a `Canvas` gesture; routing through
    /// the actor + the named-function dispatch keeps the Lua interpreter
    /// single-threaded.
    public func dispatchMiniWindowEvent(_ event: MiniWindowEvent) async {
        guard let scriptEngine, !event.callback.isEmpty else { return }
        let effects = await scriptEngine.callPluginFunction(
            event.pluginID,
            event.callback,
            [.number(Double(event.flags)), .string(event.hotspotID)]
        )
        if !effects.isEmpty { await applyScriptEffects(effects) }
    }
}
