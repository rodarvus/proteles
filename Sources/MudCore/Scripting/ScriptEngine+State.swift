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

    /// A whole-room `consider` is being sent (the session's `sendLine`, the
    /// one seam every command passes): read its output (S0b item 2).
    func noteRoomConsider() {
        stateTracker.noteRoomConsider()
    }

    /// Set (or, with `nil`, clear) the player's keyword for `name` in
    /// `area`: saved to the override store, then applied to the model.
    func setMobKeywordOverride(_ keyword: String?, for name: String, area: String) -> [ScriptEffect] {
        do {
            try keywordSources.overrides?.save(keyword, for: name, area: area)
        } catch {
            return [.echo("Couldn't save the keyword for \(name): \(error.localizedDescription)")]
        }
        return stateEffects(for: stateTracker.setKeywordOverride(keyword, for: name, area: area))
    }

    /// Where the keyword book loads from (tests point it at temporary files).
    func setKeywordSources(_ sources: MobKeywordSources) {
        keywordSources = sources
    }
}

extension ScriptEngine {
    /// Ingest one raw inbound line, returning the effects of any change.
    /// Most lines can't change state; they return before the probe, whose
    /// mode check alone takes a lock (B6, `docs/plans/S0B_ITEM1_PROPOSAL.md`).
    func ingestState(_ line: Line) -> [ScriptEffect] {
        // The two checks inline, on stored fields: calling a method on the
        // tracker would copy it per line (B6, S0B_ITEM2_PROPOSAL.md §9).
        guard line.text.utf8.first == UInt8(ascii: "{") || stateTracker.isReading else { return [] }
        let change = probe.measure("session.script.state", events: 1, thresholdMS: 50) {
            stateTracker.ingest(line)
        }
        return stateEffects(for: change)
    }

    /// Ingest one GMCP package, returning the effects of any change.
    /// `room.info` also binds named occupants to the room (S0b item 2).
    func ingestState(gmcpPackage package: String, json: String) -> [ScriptEffect] {
        stateEffects(for: stateTracker.ingest(gmcpPackage: package, json: json))
    }

    /// Forget the state on a fresh connection; the UI hears that every feed
    /// is unseen again. The keyword book is (re)loaded from disk here.
    func resetActionableState() -> [ScriptEffect] {
        stateTracker.reset()
        return stateEffects(for: stateTracker.setKeywordBook(keywordSources.loadBook()))
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
