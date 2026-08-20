import Foundation
@testable import MudCore
import Testing

@Suite("External capture links")
struct ExternalCaptureLinksTests {
    @Test("reference 1-based inclusive ranges become native command links")
    func appliesLink() {
        let line = Line(id: LineID(1), text: "help mapper")
        let json = #"[{"start":1,"stop":4,"text":"help mapper","label":"Help mapper"}]"#
        let linked = ExternalCaptureLinks.applying(json, lineIndex: 0, to: line)
        let link = linked.runs.compactMap(\.link).first
        #expect(link?.action == .sendCommand("help mapper"))
        #expect(linked.runs.last?.utf16Range == 0..<4)
    }

    @Test("per-line nested link tables select the matching captured line")
    func multilineLinks() {
        let json = #"[[{"start":1,"stop":3,"text":"one"}],[{"start":1,"stop":3,"text":"two"}]]"#
        let linked = ExternalCaptureLinks.applying(
            json, lineIndex: 1, to: Line(id: LineID(1), text: "two")
        )
        #expect(linked.runs.compactMap(\.link).first?.action == .sendCommand("two"))
    }
}
