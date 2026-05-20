import Foundation
import MudCore
@testable import MudUI
import Testing

@Suite("ConnectionManagerView smoke")
@MainActor
struct ConnectionManagerViewSmokeTests {
    @Test("View constructs with a model and an onConnect closure")
    func viewConstructs() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "proteles-cmview-test-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorldsModel(store: ProfileStore(url: url))
        // SwiftUI views are exercised through the app target + manual
        // testing; this guards against the view failing to compile or
        // construct, and that the public initializer shape is stable.
        _ = ConnectionManagerView(model: model) { _ in }
    }
}
