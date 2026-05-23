import MudCore
@testable import MudUI
import Testing

@MainActor
@Suite("SnDPanelModel — interaction surface")
struct SnDPanelModelTests {
    @Test("With no command handler the panel is non-interactive and run() is inert")
    func inertByDefault() {
        let model = SnDPanelModel()
        #expect(!model.isInteractive)
        model.run("xcp") // must not crash with no handler
        model.selectTarget(3)
    }

    @Test("A wired command handler receives toolbar + row commands verbatim")
    func dispatchesCommands() {
        let model = SnDPanelModel()
        var sent: [String] = []
        model.onCommand = { sent.append($0) }

        #expect(model.isInteractive)
        model.run("xcp")
        model.run("nx")
        model.run("xgui ref")
        model.selectTarget(5) // → "xcp 5"

        #expect(sent == ["xcp", "nx", "xgui ref", "xcp 5"])
    }

    @Test("The import affordance invokes the import handler")
    func requestsImport() {
        let model = SnDPanelModel()
        var imports = 0
        model.onImport = { imports += 1 }
        model.requestImport()
        #expect(imports == 1)
    }

    @Test("Updating from JSON decodes into the published model")
    func updatesFromJSON() {
        let model = SnDPanelModel()
        model.update(json: #"{"activity":"cp","targets":[{"index":1,"mob":"a guard"}]}"#)
        #expect(model.model?.activity == "cp")
        #expect(model.model?.targets.first?.mob == "a guard")
    }
}
