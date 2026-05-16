@testable import MudCore
import Testing

@Suite("LineID")
struct LineIDTests {
    @Test("LineID is comparable by raw")
    func lineIDComparable() {
        let lhs = LineID(1)
        let rhs = LineID(2)
        #expect(lhs < rhs)
        #expect(!(rhs < lhs))
        #expect(lhs == LineID(1))
    }

    @Test("LineID is hashable")
    func lineIDIsHashable() {
        let set: Set<LineID> = [LineID(1), LineID(2), LineID(1)]
        #expect(set.count == 2)
    }
}

@Suite("Line")
struct LineTests {
    @Test("Line constructs with empty runs by default")
    func lineConstructsWithEmptyRuns() {
        let line = Line(id: LineID(0), text: "hello")
        #expect(line.id == LineID(0))
        #expect(line.text == "hello")
        #expect(line.runs.isEmpty)
    }

    @Test("Line preserves runs in order")
    func linePreservesRuns() {
        let red = StyleAttributes(foreground: .named(.red))
        let blue = StyleAttributes(foreground: .named(.blue))
        let runs = [
            StyledRun(utf16Range: 0..<3, style: red),
            StyledRun(utf16Range: 3..<6, style: blue)
        ]
        let line = Line(id: LineID(1), text: "redblu", runs: runs)
        #expect(line.runs.count == 2)
        #expect(line.runs[0].style == red)
        #expect(line.runs[1].style == blue)
    }
}

@Suite("StyledRun")
struct StyledRunTests {
    @Test("StyledRun stores range and style")
    func styledRunStoresRangeAndStyle() {
        let run = StyledRun(
            utf16Range: 0..<5,
            style: StyleAttributes(bold: true)
        )
        #expect(run.utf16Range == 0..<5)
        #expect(run.style.bold)
    }
}
