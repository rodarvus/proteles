import Foundation
import MudCore
@testable import MudUI
import Testing

@MainActor
@Suite("Buttons tab model ops (D-106)")
struct ButtonBarModelTests {
    private static func makeModel() async throws -> ScriptsModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-buttons-tests-\(UUID().uuidString)")
        let store = ScriptStore(directory: directory, character: "test")
        try await store.load()
        let model = ScriptsModel(session: SessionController())
        model.store = store
        await model.refresh()
        return model
    }

    /// A model with one group of three named buttons.
    private static func makeSeededModel() async throws -> (ScriptsModel, UUID) {
        let model = try await makeModel()
        await model.addButtonGroup()
        let groupID = try #require(model.buttonBar.groups.first?.id)
        for label in ["alpha", "beta", "gamma"] {
            await model.addButton(toGroup: groupID)
            let id = try #require(model.selectedButtonID)
            // Set the label through the synchronous mutation path (the
            // editor's binding persists via a detached Task — racy in a test).
            await model.updateButtonBar { bar in
                for groupIndex in bar.groups.indices {
                    let buttons = bar.groups[groupIndex].buttons
                    if let buttonIndex = buttons.firstIndex(where: { $0.id == id }) {
                        bar.groups[groupIndex].buttons[buttonIndex].label = label
                    }
                }
            }
        }
        return (model, groupID)
    }

    @Test("duplicateButton: copy lands after the original, fresh id, selected")
    func duplicate() async throws {
        let (model, groupID) = try await Self.makeSeededModel()
        let original = try #require(model.buttonBar.groups.first?.buttons[1])

        await model.duplicateButton(original.id)

        let group = try #require(model.buttonBar.groups.first { $0.id == groupID })
        #expect(group.buttons.count == 4)
        let copy = group.buttons[2]
        #expect(copy.label == original.label)
        #expect(copy.id != original.id)
        #expect(model.selectedButtonID == copy.id)
    }

    @Test("moveButtons reorders within the group and persists")
    func moveButtons() async throws {
        let (model, groupID) = try await Self.makeSeededModel()

        // gamma (index 2) to the front.
        await model.moveButtons(inGroup: groupID, from: IndexSet(integer: 2), to: 0)
        #expect(model.buttonBar.groups.first?.buttons.map(\.label) == ["gamma", "alpha", "beta"])
    }

    @Test("moveButtonGroups reorders pages")
    func moveGroups() async throws {
        let model = try await Self.makeModel()
        await model.addButtonGroup()
        await model.addButtonGroup()
        let names = model.buttonBar.groups.map(\.name)

        await model.moveButtonGroups(from: IndexSet(integer: 1), to: 0)
        #expect(model.buttonBar.groups.map(\.name) == [names[1], names[0]])
    }

    @Test("buttons filter matches label, on-action, and toggle off-action")
    func buttonFilter() {
        let toggle = CommandButton(
            label: "Sanctuary",
            action: .command("cast sanc"),
            kind: .toggle(off: .command("cancel sanc"))
        )
        #expect(ScriptItemFilter.matches(toggle, query: ""))
        #expect(ScriptItemFilter.matches(toggle, query: "sanctuary"))
        #expect(ScriptItemFilter.matches(toggle, query: "CAST"))
        #expect(ScriptItemFilter.matches(toggle, query: "cancel"))
        #expect(!ScriptItemFilter.matches(toggle, query: "heal"))
    }

    @Test("requestButtonsTab bumps the observable counter")
    func tabRequest() async throws {
        let model = try await Self.makeModel()
        let before = model.buttonsTabRequests
        model.requestButtonsTab()
        #expect(model.buttonsTabRequests == before + 1)
    }
}

@MainActor
@Suite("Button fixes from live feedback (2026-06-10)")
struct ButtonLiveFeedbackTests {
    @Test("multi-line command bodies split into per-line sends; blanks dropped")
    func commandLineSplitting() {
        #expect(SessionController.commandLines("look") == ["look"])
        #expect(SessionController.commandLines("q request\nwhere") == ["q request", "where"])
        #expect(SessionController.commandLines("a\r\nb\n\n  \nc") == ["a", "b", "c"])
        #expect(SessionController.commandLines("").isEmpty)
        // `;`-stacking is the pipeline's job, per line — not split here.
        #expect(SessionController.commandLines("kill rat;loot") == ["kill rat;loot"])
    }

    @Test("an SF Symbol name is recognised; an emoji falls back to text")
    func iconFallback() {
        #expect(ButtonIconView.isSymbolName("bolt.fill"))
        #expect(!ButtonIconView.isSymbolName("🐯"))
        #expect(!ButtonIconView.isSymbolName("not.a.real.symbol.name"))
    }
}
