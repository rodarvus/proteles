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
}
