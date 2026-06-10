import Foundation
@testable import MudCore
import Testing

@Suite("Core-feature enablement store (D-107)")
struct CoreFeatureStoreTests {
    private func makeStore() -> CoreFeatureStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-corefeatures-\(UUID().uuidString)")
            .appendingPathComponent("coreFeatures.json")
        return CoreFeatureStore(url: url)
    }

    @Test("a missing file means nothing is disabled")
    func emptyDefault() async {
        let store = makeStore()
        await store.load()
        let disabled = await store.disabled(forProfile: UUID())
        #expect(disabled.isEmpty)
    }

    @Test("disable persists per profile and round-trips through disk")
    func roundTrip() async throws {
        let store = makeStore()
        await store.load()
        let profile = UUID()
        let other = UUID()

        try await store.setEnabled(false, featureID: "mapper", forProfile: profile)
        try await store.setEnabled(false, featureID: "dinv", forProfile: profile)
        #expect(await store.disabled(forProfile: profile) == ["mapper", "dinv"])
        #expect(await store.disabled(forProfile: other).isEmpty)

        // A fresh store reading the same file sees the same state.
        let reread = CoreFeatureStore(url: store.url)
        await reread.load()
        #expect(await reread.disabled(forProfile: profile) == ["mapper", "dinv"])

        // Re-enabling removes the entry (back to the everything-on default).
        try await reread.setEnabled(true, featureID: "mapper", forProfile: profile)
        try await reread.setEnabled(true, featureID: "dinv", forProfile: profile)
        #expect(await reread.disabled(forProfile: profile).isEmpty)
    }

    @Test("the governed feature ids match the Plugins window's rows")
    func featureIDs() {
        #expect(CoreFeatureStore.featureIDs
            == ["mapper", "dinv", "leveldb", "search-and-destroy"])
    }
}

@Suite("Plugin command hints (D-107, best effort)")
struct PluginCommandHintsTests {
    @Test("typed-command regexes simplify to readable hints")
    func regexSimplification() {
        #expect(PluginCommandHints.humanize(.regex(#"^dinv\s+(.+)$"#)) == "dinv …")
        #expect(PluginCommandHints.humanize(.regex(#"^ldb (daily|level)$"#)) == "ldb …")
        #expect(PluginCommandHints.humanize(.regex("^xcp$")) == "xcp")
        #expect(PluginCommandHints.humanize(.regex(#"^quests?$"#)) == "quests")
    }

    @Test("wildcards flatten; catch-alls and non-commands drop")
    func wildcardsAndCatchAlls() {
        #expect(PluginCommandHints.humanize(.wildcard("k *")) == "k …")
        #expect(PluginCommandHints.humanize(.exact("ak")) == "ak")
        #expect(PluginCommandHints.humanize(.wildcard("*")) == nil)
        #expect(PluginCommandHints.humanize(.regex("^(.*)$")) == nil)
    }

    @Test("hint lists dedupe and alphabetise")
    func listShape() {
        let aliases = [
            Alias(pattern: .regex(#"^zz\s+(.*)$"#)),
            Alias(pattern: .exact("ak")),
            Alias(pattern: .regex(#"^zz\s+(.+)$"#)) // dupe after simplification
        ]
        #expect(PluginCommandHints.from(aliases: aliases) == ["ak", "zz …"])
    }
}
