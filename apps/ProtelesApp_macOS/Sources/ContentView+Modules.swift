import Foundation
import MudCore

extension ContentView {
    /// Keep module chrome current without requiring the Plugins window to open,
    /// and remove obsolete dock placements retained by older layout JSON.
    func observeModuleListings(profileID: UUID?) async {
        layout.removeEverywhere(.help)
        layout.removeEverywhere(.market)
        if let profileID { await plugins.prepare(profileID: profileID) }
        await plugins.refreshNative()
        for await listing in session.moduleListings {
            plugins.applyModuleListing(listing)
        }
    }

    func applyHelpModulePresentation() {
        if plugins.moduleEnabled(SessionController.helpModuleID) {
            help.onCommand = { command in Task { try? await session.send(command) } }
        } else {
            help.reset()
            layout.removeEverywhere(.help)
            dismissWindow(id: ProtelesApp.helpWindowID)
        }
    }

    func applyMarketplaceModulePresentation() {
        if plugins.moduleEnabled(SessionController.marketplaceModuleID) {
            market.onCommand = { command in Task { try? await session.send(command) } }
        } else {
            market.reset()
            layout.removeEverywhere(.market)
            dismissWindow(id: ProtelesApp.marketWindowID)
        }
    }

    func consumeHelpArticles() async {
        for await article in session.helpArticles {
            guard await session.isModuleEnabled(id: SessionController.helpModuleID) else { continue }
            await help.apply(article)
            openWindow(id: ProtelesApp.helpWindowID)
        }
    }

    func consumeMarketCaptures() async {
        for await capture in session.marketCaptures {
            guard await session.isModuleEnabled(id: SessionController.marketplaceModuleID) else { continue }
            market.apply(capture)
            openWindow(id: ProtelesApp.marketWindowID)
        }
    }
}
