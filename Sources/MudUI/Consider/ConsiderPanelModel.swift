import MudCore
import Observation
import SwiftUI

/// `@Observable` bridge for the floating Consider panel: holds the latest
/// ``ConsiderSnapshot`` the native feature published and turns the panel's
/// controls into `conw…` commands routed back through the session.
@MainActor
@Observable
public final class ConsiderPanelModel {
    public private(set) var snapshot = ConsiderSnapshot()

    /// Run a `conw…` command (handled by the native ConsiderFeature). The app
    /// wires this to `session.send`; `nil` (the default) makes the panel inert
    /// (render-only, e.g. previews).
    @ObservationIgnored public var onCommand: (@MainActor (String) -> Void)?

    public init(snapshot: ConsiderSnapshot = ConsiderSnapshot()) {
        self.snapshot = snapshot
    }

    /// Replace the model from a published snapshot.
    public func update(_ snapshot: ConsiderSnapshot) {
        self.snapshot = snapshot
    }

    /// Whether the panel's controls should act (a command handler is wired).
    public var isInteractive: Bool {
        onCommand != nil
    }

    private func run(_ command: String) {
        onCommand?(command)
    }

    /// Re-run `consider all` now.
    public func refresh() {
        run("conw")
    }

    /// Attack the mob at 1-based list position `position` with the default
    /// command (the original miniwindow's click-to-attack).
    public func attack(_ position: Int) {
        run("conw \(position)")
    }

    /// Run the `conwall` batch sweep.
    public func attackAll() {
        run("conwall")
    }

    /// Toggle auto-refresh on/off.
    public func toggleEnabled() {
        run(snapshot.enabled ? "conw off" : "conw on")
    }

    /// Change how attack targets are formatted.
    public func setMode(_ mode: ConsiderExecuteMode) {
        run("conw mode \(mode.rawValue)")
    }
}
