@testable import MudCore
import Testing

@Suite("MudCore smoke")
struct MudCoreSmokeTests {
    @Test("Version string is populated")
    func versionStringIsSet() {
        #expect(!MudCore.version.isEmpty)
    }

    @Test("Logger label uses the project namespace")
    func loggerLabelIsNamespaced() {
        #expect(MudCore.loggerLabel.hasPrefix("com.proteles."))
    }
}
