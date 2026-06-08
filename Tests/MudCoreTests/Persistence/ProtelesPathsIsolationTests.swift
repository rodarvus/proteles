import Foundation
@testable import MudCore
import Testing

@Suite("ProtelesPaths — test-harness isolation (#45)")
struct ProtelesPathsIsolationTests {
    @Test("home() sandboxes under the test harness — never the real ~/Documents")
    func homeSandboxed() throws {
        let home = try ProtelesPaths.home()
        if let realDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            #expect(home.path != realDocs.appendingPathComponent("Proteles").path)
        }
        // Confirms the XCTestConfigurationFilePath detection fires in this runner.
        #expect(home.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test("a plugin DB path lands in the sandbox, not the user's Databases")
    func pluginDatabaseSandboxed() throws {
        let url = try ProtelesPaths.pluginDatabaseURL(character: "Tester", fileName: "x.db")
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(url.lastPathComponent == "x.db")
    }
}
