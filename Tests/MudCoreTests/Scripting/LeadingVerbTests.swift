@testable import MudCore
import Testing

@Suite("TriggerPattern.leadingVerb (#31)")
struct LeadingVerbTests {
    @Test("extracts a clean leading verb, or nil")
    func extractsVerbs() {
        #expect(TriggerPattern.exact("kk").leadingVerb == "kk")
        #expect(TriggerPattern.beginsWith("kk ").leadingVerb == "kk")
        #expect(TriggerPattern.wildcard("kk *").leadingVerb == "kk")
        #expect(TriggerPattern.wildcard("cast *").leadingVerb == "cast")
        #expect(TriggerPattern.exact("KK").leadingVerb == "kk") // lowercased
        #expect(TriggerPattern.substring("foo").leadingVerb == nil)
        #expect(TriggerPattern.regex("^kk").leadingVerb == nil)
        #expect(TriggerPattern.exact("").leadingVerb == nil)
    }
}
