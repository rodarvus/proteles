import Foundation

/// The actionable-state seams (S0b item 1, #84;
/// `docs/plans/S0B_ITEM1_PROPOSAL.md`). The tracker is fed inside passes
/// already running on this actor — `process(_:)` for lines, `applyGMCP` for
/// packets — so state costs no actor hop per line.
///
/// A change reaches two kinds of consumer, both as effects that ride the
/// line's or packet's own effects (applied on the displayed and gagged paths
/// alike):
/// - native plugins, through ``NativePlugin/onStateChange(_:changed:)``, only
///   when an entity changed;
/// - the UI, through `.updateState`, on any change, feed status included.
public extension ScriptEngine {
    /// The current actionable state.
    var actionableState: ActionableState {
        stateTracker.state
    }
}

extension ScriptEngine {
    /// Ingest one raw inbound line, returning the effects of any change.
    /// Most lines can't change state; they return before the probe, whose
    /// mode check alone takes a lock (B6, `docs/plans/S0B_ITEM1_PROPOSAL.md`).
    func ingestState(_ line: Line) -> [ScriptEffect] {
        guard stateTracker.mayChange(on: line) else { return [] }
        let change = probe.measure("session.script.state", events: 1, thresholdMS: 50) {
            stateTracker.ingest(line)
        }
        return stateEffects(for: change)
    }

    /// Ingest one GMCP package, returning the effects of any change.
    func ingestState(gmcpPackage package: String) -> [ScriptEffect] {
        stateEffects(for: stateTracker.ingest(gmcpPackage: package))
    }

    /// Forget the state on a fresh connection; the UI hears that every feed
    /// is unseen again.
    func resetActionableState() -> [ScriptEffect] {
        stateTracker.reset()
        return [.updateState(stateTracker.state)]
    }

    private func stateEffects(for change: ActionableStateTracker.Change) -> [ScriptEffect] {
        guard change.state else { return [] }
        var effects: [ScriptEffect] = []
        if !change.entities.isEmpty {
            effects = nativePlugins.onStateChange(stateTracker.state, changed: change.entities)
        }
        effects.append(.updateState(stateTracker.state))
        return effects
    }
}
