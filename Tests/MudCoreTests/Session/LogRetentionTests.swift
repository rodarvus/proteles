import Foundation
@testable import MudCore
import Testing

@Suite("LogRetention — keep newest N session logs")
struct LogRetentionTests {
    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/logs/\($0)") }
    }

    @Test("Prunes the oldest beyond the limit (newest = largest timestamp name)")
    func prunesOldest() {
        let files = urls([
            "session-2026-05-29-090000.txt",
            "session-2026-05-29-100000.txt",
            "session-2026-05-29-110000.txt"
        ])
        let pruned = LogRetention.filesToPrune(files, keeping: 2).map(\.lastPathComponent)
        #expect(pruned == ["session-2026-05-29-090000.txt"]) // oldest only
    }

    @Test("At or under the limit prunes nothing")
    func underLimit() {
        let files = urls(["a.txt", "b.txt"])
        #expect(LogRetention.filesToPrune(files, keeping: 2).isEmpty)
        #expect(LogRetention.filesToPrune(files, keeping: 5).isEmpty)
    }

    @Test("keep <= 0 is treated as keep-everything (never wipes the folder)")
    func zeroKeepsAll() {
        let files = urls(["a.txt", "b.txt"])
        #expect(LogRetention.filesToPrune(files, keeping: 0).isEmpty)
    }
}
