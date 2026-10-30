import MudCore
import Observation

/// `@Observable` holder for the live ``ActionableState`` (S0b, #84). Only
/// the State inspector reads `state`, inside its own body, so a published
/// snapshot re-renders that window alone (`GMCPStateModel`'s lesson).
@MainActor
@Observable
public final class ActionableStateModel {
    public private(set) var state: ActionableState

    public init(state: ActionableState = ActionableState()) {
        self.state = state
    }

    /// Follow the session's snapshots for as long as the caller's task lives.
    public func run(states: AsyncStream<ActionableState>) async {
        for await snapshot in states {
            state = snapshot
        }
    }
}
