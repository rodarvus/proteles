import Foundation
@testable import MudCore
import Testing

@Suite("SessionController — Help and Marketplace modules", .serialized)
struct AppModuleLifecycleTests {
    private func store() -> NativePluginStore {
        NativePluginStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-modules-\(UUID().uuidString).json"))
    }

    private func line(_ id: UInt64, _ text: String) -> Line {
        Line(id: LineID(id), text: text)
    }

    @Test("Both app modules are listed and enabled by default")
    func defaultListing() async {
        let session = SessionController()
        let listing = await session.moduleListing()
        #expect(listing.first { $0.metadata.id == SessionController.helpModuleID }?.enabled == true)
        #expect(listing.first { $0.metadata.id == SessionController.marketplaceModuleID }?.enabled == true)
    }

    @Test("Profile documents reset missing module ids to their enabled default")
    func profileIsolation() async throws {
        let session = SessionController()
        let disabled = store()
        try await disabled.setEnabled(false, id: SessionController.helpModuleID)
        try await disabled.setEnabled(false, id: SessionController.marketplaceModuleID)
        await session.attachNativePluginStore(disabled)
        #expect(await session.isModuleEnabled(id: SessionController.helpModuleID) == false)
        #expect(await session.isModuleEnabled(id: SessionController.marketplaceModuleID) == false)

        await session.attachNativePluginStore(store())
        #expect(await session.isModuleEnabled(id: SessionController.helpModuleID) == true)
        #expect(await session.isModuleEnabled(id: SessionController.marketplaceModuleID) == true)
    }

    @Test("Disabled Help leaves tagged output in the normal line pipeline")
    func disabledHelpPassesThrough() async {
        let session = SessionController()
        await session.setHelpCaptureEnabled(false)
        let open = await session.appendLineThroughScripts(line(1, "{help}"))
        let body = await session.appendLineThroughScripts(line(2, "ordinary help body"))
        #expect(open.displayed == 1)
        #expect(body.displayed == 1)
    }

    @Test("Disabling Marketplace clears an in-flight command capture")
    func disabledMarketClearsCapture() async {
        let session = SessionController()
        await session.armMarketCapture(for: "lbid 63213")
        await session.setMarketCaptureEnabled(false)
        let result = await session.appendLineThroughScripts(line(1, "| Market Item Number : 63213 |"))
        #expect(result.displayed == 1)
    }

    @Test("Help enable and disable send exact Aardwolf telnet option bytes")
    func helpTelnetLifecycle() async throws {
        let connection = InMemoryConnection()
        let session = SessionController(makeConnection: { connection })
        try await session.connect(to: .init(host: "test.invalid", port: 23))

        await session.setHelpCaptureEnabled(false)
        await session.setHelpCaptureEnabled(true)
        await session.setHelpCaptureEnabled(false)

        let on: [UInt8] = [255, 250, 102, 3, 1, 255, 240]
        let off: [UInt8] = [255, 250, 102, 3, 2, 255, 240]
        #expect(connection.sentBytes.contains(on))
        #expect(connection.sentBytes.contains(off))
        await session.disconnect()
    }
}
