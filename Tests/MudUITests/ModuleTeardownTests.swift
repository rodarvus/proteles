import Foundation
import MudCore
@testable import MudUI
import Testing

@MainActor
@Suite("App module UI teardown")
struct ModuleTeardownTests {
    @Test("Help reset removes history, content, and command routing")
    func helpReset() async {
        let model = HelpPanelModel()
        model.onCommand = { _ in }
        await model.apply(HelpArticle(
            title: "Consider",
            lines: [Line(id: LineID(1), text: "help body")],
            isSearch: false
        ))
        model.reset()
        #expect(model.hasContent == false)
        #expect(model.title == "Help")
        #expect(model.onCommand == nil)
    }

    @Test("Marketplace reset removes listings, filters, bid state, and routing")
    func marketReset() {
        let model = MarketPanelModel()
        model.onCommand = { _ in }
        model.apply(.init(kind: .list(.standard), lines: [
            Line(id: LineID(1), text: " 63213 the Lemniscate 121 Gold 19,500,000 10 2d 01:39:53")
        ]))
        model.activeFilter = .mine
        model.bidAmount = "1000"
        model.proxyBid = true
        model.prepareBid()
        model.reset()
        #expect(model.items.isEmpty)
        #expect(model.selectedItemNumber == nil)
        #expect(model.activeFilter == nil)
        #expect(model.bidAmount.isEmpty)
        #expect(model.proxyBid == false)
        #expect(model.bidReview == nil)
        #expect(model.onCommand == nil)
    }

    @Test("Legacy dedicated panels are removed from layouts and presets")
    func legacyLayoutRemoval() {
        let key = "proteles-layout-module-test-\(UUID().uuidString)"
        let presetKey = key + ".presets"
        let store = LayoutStore(persistenceKey: key, presetsKey: presetKey)
        store.layout = store.layout.inserting(.help).inserting(.market)
        store.savePreset(named: "Legacy")
        store.float(.help)
        store.detach(.market)

        store.removeEverywhere(.help)
        store.removeEverywhere(.market)

        #expect(!store.isVisible(.help))
        #expect(!store.isVisible(.market))
        #expect(store.presets.allSatisfy {
            !$0.layout.contains(.help) && !$0.layout.contains(.market)
                && !$0.floating.contains(.help) && !$0.floating.contains(.market)
        })
    }
}
