import Foundation
@testable import MudCore
import Testing

@Suite("TextSubstitution — #sub/#gag plugin")
struct TextSubstitutionTests {
    private func line(_ text: String) -> Line {
        Line(id: LineID(1), text: text)
    }

    private func isGag(_ disposition: ScriptEngine.LineDisposition) -> Bool {
        disposition.gag
    }

    private func replacedText(_ disposition: ScriptEngine.LineDisposition) -> String? {
        disposition.replacement?.text
    }

    @Test("#sub adds a rule that rewrites matching lines, and persists")
    func addSub() {
        var plugin = TextSubstitution()
        let effects = plugin.handleCommand("#sub {potato} {pants}")
        #expect(effects?.contains(.persistPluginState(id: plugin.metadata.id)) == true)
        #expect(replacedText(plugin.onLine(line("a potato here"))) == "a pants here")
    }

    @Test("#gag adds a rule that drops matching lines")
    func addGag() {
        var plugin = TextSubstitution()
        _ = plugin.handleCommand("#gag {spam}")
        #expect(isGag(plugin.onLine(line("this is spam"))))
        #expect(!isGag(plugin.onLine(line("clean line"))))
    }

    @Test("Flags are parsed (#nocase makes the rule case-insensitive)")
    func flags() {
        var plugin = TextSubstitution()
        _ = plugin.handleCommand("#sub {hp} {health} #nocase")
        #expect(replacedText(plugin.onLine(line("HP low"))) == "health low")
    }

    @Test("Without #nocase a substitution is case-sensitive (faithful to the original)")
    func caseSensitiveByDefault() {
        var plugin = TextSubstitution()
        _ = plugin.handleCommand("#sub {hp} {health}")
        #expect(plugin.onLine(line("HP low")).replacement == nil) // no match: different case
        #expect(replacedText(plugin.onLine(line("hp low"))) == "health low")
    }

    @Test("#unsub removes a substitution by number")
    func unsub() {
        var plugin = TextSubstitution()
        _ = plugin.handleCommand("#sub {a} {b}")
        _ = plugin.handleCommand("#unsub #1")
        #expect(plugin.onLine(line("a")).replacement == nil)
    }

    @Test("Unrelated input is not handled")
    func passthrough() {
        var plugin = TextSubstitution()
        #expect(plugin.handleCommand("look") == nil)
        #expect(plugin.handleCommand("say #hi") == nil)
    }

    @Test("Listing and help return output without mutating")
    func listingAndHelp() {
        var plugin = TextSubstitution()
        #expect(plugin.handleCommand("#subs")?.isEmpty == false)
        let help = plugin.handleCommand("#sub help")
        #expect((help?.count ?? 0) > 3)
        // Help/list must not request a persist.
        #expect(help?.contains(.persistPluginState(id: plugin.metadata.id)) == false)
    }

    @Test("State round-trips through persistentState/restore")
    func persistenceRoundTrip() {
        var source = TextSubstitution()
        _ = source.handleCommand("#sub {potato} {pants}")
        _ = source.handleCommand("#gag {spam}")
        guard let data = source.persistentState else { Issue.record("no state"); return }

        var restored = TextSubstitution()
        restored.restore(from: data)
        #expect(replacedText(restored.onLine(line("a potato"))) == "a pants")
        #expect(isGag(restored.onLine(line("spam here"))))
    }
}
