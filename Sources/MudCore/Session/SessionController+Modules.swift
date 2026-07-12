import Foundation

/// Built-in app modules that live at the session's pre-script seam rather than
/// inside ``NativePluginRegistry``. Their metadata is still surfaced alongside
/// native plugins under Plugins ▸ Modules.
public extension SessionController {
    static let helpModuleID = "com.proteles.help"
    static let marketplaceModuleID = "com.proteles.marketplace"

    func moduleListing() async -> [NativePluginInfo] {
        let native = await scriptEngine?.nativePluginListing() ?? []
        return native + appModuleListing
    }

    func isModuleEnabled(id: String) async -> Bool {
        switch id {
        case Self.helpModuleID: helpCaptureEnabled
        case Self.marketplaceModuleID: marketCaptureEnabled
        default: await scriptEngine?.isNativePluginEnabled(id: id) ?? false
        }
    }

    /// Persist and apply a module toggle. Persistence happens first so a failed
    /// write cannot create a live state that silently reverses after relaunch.
    func setModuleEnabled(_ enabled: Bool, id: String) async throws {
        if let nativePluginStore {
            try await nativePluginStore.setEnabled(enabled, id: id)
        }
        await applyModuleEnabled(enabled, id: id)
        await publishModuleListing()
    }

    func publishModuleListing() async {
        await moduleListingsContinuation.yield(moduleListing())
    }

    private var appModuleListing: [NativePluginInfo] {
        [
            NativePluginInfo(
                metadata: NativePluginMetadata(
                    id: Self.helpModuleID,
                    name: "Game Help",
                    summary: "Captures Aardwolf help into a searchable native window "
                        + "with clickable references."
                ),
                help: NativePluginHelp(
                    overview: "Shows tagged in-game help in its own window. When disabled, "
                        + "help output remains in the game window.",
                    commands: [
                        .init(syntax: "help <topic>", summary: "Open an Aardwolf help topic."),
                        .init(syntax: "help search <text>", summary: "Search Aardwolf help files.")
                    ]
                ),
                enabled: helpCaptureEnabled
            ),
            NativePluginInfo(
                metadata: NativePluginMetadata(
                    id: Self.marketplaceModuleID,
                    name: "Marketplace",
                    summary: "Native marketplace listings, item details, bid history, and guarded bid review."
                ),
                help: NativePluginHelp(
                    overview: "Captures marketplace responses into a buyer-focused window. "
                        + "When disabled, market commands use normal game output.",
                    commands: [
                        .init(syntax: "lbid", summary: "List current marketplace auctions."),
                        .init(syntax: "lbid <number>", summary: "Show an auction's details."),
                        .init(syntax: "lbid <number> history", summary: "Show bid history.")
                    ]
                ),
                enabled: marketCaptureEnabled
            )
        ]
    }

    func applyModuleEnabled(_ enabled: Bool, id: String) async {
        switch id {
        case Self.helpModuleID:
            await setHelpCaptureEnabled(enabled)
        case Self.marketplaceModuleID:
            setMarketCaptureEnabled(enabled)
        default:
            guard let scriptEngine else { return }
            await applyScriptEffects(scriptEngine.setNativePluginEnabled(enabled, id: id))
        }
    }
}
