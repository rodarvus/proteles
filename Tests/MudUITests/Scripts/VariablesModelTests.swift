import Foundation
import MudCore
@testable import MudUI
import Testing

/// The Variables tab's model CRUD (#69). The model talks to a live
/// ``SessionController`` (real ``ScriptEngine`` + attached ``VariableStore``),
/// so these exercise the whole UI→session→runtime→store path.
@MainActor
@Suite("Variables tab model ops (#69)")
struct VariablesModelTests {
    private static func makeModel() async throws -> ScriptsModel {
        let engine = try ScriptEngine()
        let session = SessionController(scriptEngine: engine)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-varmodel-\(UUID().uuidString).json")
        await session.attachVariableStore(VariableStore(url: url))
        return ScriptsModel(session: session)
    }

    @Test("addVariable creates a _user variable and selects it")
    func add() async throws {
        let model = try await Self.makeModel()
        await model.addVariable()
        #expect(model.variables.count == 1)
        let entry = try #require(model.variables.first)
        #expect(entry.scope == VariableEntry.userScope)
        #expect(model.selectedVariableID == entry.id)
    }

    @Test("addVariable generates unique default names")
    func uniqueNames() async throws {
        let model = try await Self.makeModel()
        await model.addVariable()
        await model.addVariable()
        #expect(Set(model.variables.map(\.name)) == ["variable", "variable_2"])
    }

    @Test("valueBinding updates the row synchronously")
    func editValue() async throws {
        let model = try await Self.makeModel()
        await model.addVariable()
        let id = try #require(model.selectedVariableID)
        let binding = try #require(model.valueBinding(forVariable: id))
        binding.wrappedValue = "100"
        #expect(model.variableEntry(id)?.value == "100")
    }

    @Test("renameVariable moves the value and reselects under the new id")
    func rename() async throws {
        let model = try await Self.makeModel()
        await model.addVariable()
        let id = try #require(model.selectedVariableID)
        await model.renameVariable(id: id, to: "target")
        let entry = try #require(model.variables.first)
        #expect(entry.name == "target")
        #expect(model.selectedVariableID == entry.id)
    }

    @Test("deleteSelectedVariable removes it")
    func delete() async throws {
        let model = try await Self.makeModel()
        await model.addVariable()
        #expect(model.variables.count == 1)
        await model.deleteSelectedVariable()
        #expect(model.variables.isEmpty)
    }

    @Test("refreshVariables sorts the user scope ahead of plugin scopes")
    func sorting() async throws {
        let model = try await Self.makeModel()
        await model.session.setVariable(scope: "pluginZ", name: "z", value: "1")
        await model.session.setVariable(scope: VariableEntry.userScope, name: "a", value: "1")
        await model.refreshVariables()
        #expect(model.variables.first?.scope == VariableEntry.userScope)
    }
}
