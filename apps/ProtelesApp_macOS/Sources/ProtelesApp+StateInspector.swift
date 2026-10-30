import MudCore
import MudUI
import SwiftUI

/// The State inspector window (S0b item 1, #84): a read-only view of the
/// actionable-state model, opened from Settings ▸ Development, with no
/// menu-bar item (DESIGN.md §3.5; `docs/plans/S0B_ITEM1_PROPOSAL.md`).
extension ProtelesApp {
    static let stateInspectorWindowID = "stateInspector"

    var stateInspectorWindow: some Scene {
        Window("State", id: Self.stateInspectorWindowID) {
            StateInspectorView(model: actionableState)
                .frame(minWidth: 420, idealWidth: 520, minHeight: 360, idealHeight: 520)
                .navigationTitle("State")
        }
        .defaultSize(width: 520, height: 520)
    }

    /// A model fed the session's state snapshots for the app's lifetime, so
    /// the window shows the latest state whenever it opens.
    static func followActionableState(session: SessionController) -> ActionableStateModel {
        let model = ActionableStateModel()
        Task { @MainActor in
            await model.run(states: session.actionableStates)
        }
        return model
    }
}
