import MudCore
import Observation
import SwiftUI

/// `@Observable` bridge for the Search-and-Destroy dock panel: holds the
/// latest model S&D published (via the S2 JSON snapshot). Live feeding from a
/// running S&D instance is wired in the app-integration stage; the render-only
/// panel works off whatever model is set here.
@MainActor
@Observable
public final class SnDPanelModel {
    public private(set) var model: SearchAndDestroyModel?

    /// Run an S&D command (an alias the running plugin handles, e.g. `xcp`,
    /// `nx`, `xgui ref`, or `xcp <index>` for a target click). The app wires
    /// this to live S&D command dispatch; `nil` (the default) makes the
    /// panel's controls inert (render-only, e.g. previews).
    @ObservationIgnored public var onCommand: (@MainActor (String) -> Void)?

    /// Request the "import a SnDdb.db" flow (file picker → incremental merge).
    /// Wired by the app; `nil` hides the affordance's effect.
    @ObservationIgnored public var onImport: (@MainActor () -> Void)?

    /// Force a campaign/quest detection pass (S&D's `do_cp_info`). Wired by
    /// the app to the session; lets the player detect an already-running
    /// campaign that wasn't auto-detected on the grant line.
    @ObservationIgnored public var onScan: (@MainActor () -> Void)?

    public init(model: SearchAndDestroyModel? = nil) {
        self.model = model
    }

    /// Replace the model from a published JSON snapshot.
    public func update(json: String) {
        if let decoded = SearchAndDestroyModel.decode(json) { model = decoded }
    }

    /// Replace the model directly (e.g. previews/tests).
    public func update(_ model: SearchAndDestroyModel?) {
        self.model = model
    }

    /// Whether the panel's controls should act (a command handler is wired).
    public var isInteractive: Bool {
        onCommand != nil
    }

    /// Dispatch an S&D command, if a handler is wired.
    public func run(_ command: String) {
        onCommand?(command)
    }

    /// Click a target row: re-target it via S&D's `xcp <index>` (the same path
    /// the original miniwindow's clickable target link used).
    public func selectTarget(_ index: Int) {
        run("xcp \(index)")
    }

    /// Trigger the SnDdb.db import flow, if wired.
    public func requestImport() {
        onImport?()
    }

    /// Force a campaign/quest detection pass, if wired.
    public func scan() {
        onScan?()
    }
}
