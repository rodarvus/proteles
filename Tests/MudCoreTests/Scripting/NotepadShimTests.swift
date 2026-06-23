import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — notepad shim compatibility")
struct NotepadShimTests {
    private static let notepadProbeScript = """
    proteles.echo("missing-len:" .. tostring(GetNotepadLength("output")))
    proteles.echo("append:" .. tostring(AppendToNotepad("Output", "abc", "def")))
    proteles.echo("append2:" .. tostring(AppendToNotepad("output", "-", "ghi")))
    proteles.echo("text:" .. GetNotepadText("OUTPUT"))
    proteles.echo("len:" .. tostring(GetNotepadLength("output")))
    proteles.echo("replace:" .. tostring(ReplaceNotepad("output", "x", "y", "z")))
    proteles.echo("text2:" .. GetNotepadText("Output"))
    proteles.echo("sendto:" .. tostring(SendToNotepad("sent", "one", "two")))
    proteles.echo("senttext:" .. GetNotepadText("sent"))
    proteles.echo("activate:" .. tostring(ActivateNotepad("OUTPUT")))
    proteles.echo("missingactivate:" .. tostring(ActivateNotepad("missing")))
    proteles.echo("move:" .. tostring(MoveNotepadWindow("output", 1, 2, 300, 400)))
    proteles.echo("pos:" .. table.concat({ GetNotepadWindowPosition("output") }, ","))
    proteles.echo("colour:" .. tostring(NotepadColour("output", 255, 0) == error_code.eOK))
    local ok = NotepadFont("output", "Courier", 12, true, false) == error_code.eOK
    proteles.echo("font:" .. tostring(ok))
    proteles.echo("save:" .. tostring(NotepadSaveMethod("output", 2)))
    proteles.echo("savebad:" .. tostring(NotepadSaveMethod("output", 9)))
    proteles.echo("readonly:" .. tostring(NotepadReadOnly("output", true)))
    proteles.echo("list:" .. table.concat(GetNotepadList(), ","))
    proteles.echo("savenote:" .. tostring(SaveNotepad("output", "", false) == error_code.eOK))
    proteles.echo("utilsreplace:" .. tostring(utils.appendtonotepad("util", "a\\nb", true)))
    proteles.echo("utiltext:" .. GetNotepadText("util"))
    proteles.echo("utilsappend:" .. tostring(utils.appendtonotepad("util", "c", false)))
    proteles.echo("utiltext2:" .. GetNotepadText("util"))
    proteles.echo("utilsactivate:" .. tostring(utils.activatenotepad("util")))
    proteles.echo("closesent:" .. tostring(CloseNotepad("sent", false) == error_code.eOK))
    proteles.echo("sentgone:" .. tostring(GetNotepadLength("sent")))
    proteles.echo("sel:" .. table.concat({
      GetSelectionStartLine(), GetSelectionEndLine(),
      GetSelectionStartColumn(), GetSelectionEndColumn()
    }, ","))
    proteles.echo("setsel:" .. tostring(select("#", SetSelection(1, 1, 1, 1))))
    """

    private static let expectedEchoes = [
        "missing-len:0",
        "append:true",
        "append2:true",
        "text:abcdef-ghi",
        "len:10",
        "replace:true",
        "text2:xyz",
        "sendto:true",
        "senttext:onetwo",
        "activate:true",
        "missingactivate:false",
        "move:true",
        "pos:1,2,300,400",
        "colour:true",
        "font:true",
        "save:true",
        "savebad:false",
        "readonly:true",
        "list:Output,sent",
        "savenote:true",
        "utilsreplace:true",
        "utiltext:a\r\nb",
        "utilsappend:true",
        "utiltext2:a\r\nbc",
        "utilsactivate:true",
        "closesent:true",
        "sentgone:0",
        "sel:0,0,0,0",
        "setsel:0"
    ]

    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("notepad APIs provide an in-memory text store; selection reports none")
    func notepadAndSelectionStubs() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run(Self.notepadProbeScript)
        let echoes = effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
        #expect(echoes == Self.expectedEchoes)
    }
}
