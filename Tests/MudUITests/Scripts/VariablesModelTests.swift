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

    @Test("commitVariable adds a new user variable and selects it")
    func add() async throws {
        let model = try await Self.makeModel()
        await model.commitVariable(editing: nil, name: "target", value: "kobold")
        let entry = try #require(model.variables.first)
        #expect(model.variables.count == 1)
        #expect(entry.scope == VariableEntry.userScope)
        #expect(entry.name == "target")
        #expect(entry.value == "kobold")
        #expect(model.selectedVariableID == entry.id)
    }

    @Test("commitVariable edits the value of an existing variable in place")
    func editValue() async throws {
        let model = try await Self.makeModel()
        await model.commitVariable(editing: nil, name: "hp", value: "1")
        let original = try #require(model.variables.first)
        await model.commitVariable(editing: original, name: "hp", value: "100")
        #expect(model.variables.count == 1)
        #expect(model.variables.first?.value == "100")
    }

    @Test("commitVariable renames, carrying the value to the new name")
    func rename() async throws {
        let model = try await Self.makeModel()
        await model.commitVariable(editing: nil, name: "old", value: "v")
        let original = try #require(model.variables.first)
        await model.commitVariable(editing: original, name: "new", value: "v")
        #expect(model.variables.count == 1)
        let entry = try #require(model.variables.first)
        #expect(entry.name == "new")
        #expect(entry.value == "v")
        #expect(model.selectedVariableID == entry.id)
    }

    @Test("commitVariable trims the name and ignores an empty one")
    func trimAndIgnoreEmpty() async throws {
        let model = try await Self.makeModel()
        await model.commitVariable(editing: nil, name: "   ", value: "x")
        #expect(model.variables.isEmpty)
        await model.commitVariable(editing: nil, name: "  spaced  ", value: "x")
        #expect(model.variables.first?.name == "spaced")
    }

    @Test("deleteSelectedVariable removes it")
    func delete() async throws {
        let model = try await Self.makeModel()
        await model.commitVariable(editing: nil, name: "a", value: "1")
        #expect(model.variables.count == 1)
        await model.deleteSelectedVariable()
        #expect(model.variables.isEmpty)
    }

    @Test("refreshVariables shows only the user scope — plugin variables excluded")
    func userScopeOnly() async throws {
        let model = try await Self.makeModel()
        await model.session.setVariable(scope: "pluginZ", name: "z", value: "1")
        await model.session.setVariable(scope: VariableEntry.userScope, name: "a", value: "1")
        await model.refreshVariables()
        #expect(model.variables.count == 1)
        #expect(model.variables.first?.scope == VariableEntry.userScope)
        #expect(model.variables.first?.name == "a")
    }
}
