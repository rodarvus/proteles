import Foundation
@testable import MudCore
import Testing

@Suite("SessionController — pasted command links", .serialized)
struct PastedCommandLinkTests {
    @Test("a pasted server command is decoded before reaching the wire")
    func pastedServerCommand() async throws {
        let connection = InMemoryConnection()
        let controller = SessionController(makeConnection: { connection })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("proteles-cmd:///look%20sign")

        #expect(connection.sentLines == ["look sign"])
        await controller.disconnect()
    }

    @Test("a pasted native mapper command stays local")
    func pastedMapperCommandStaysLocal() async throws {
        let mapURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-command-link-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: mapURL) }

        let mapper = try Mapper(store: MapperStore(url: mapURL))
        let connection = InMemoryConnection()
        let controller = SessionController(makeConnection: { connection })
        await controller.attachMapper(mapper)
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("proteles-cmd:///mapper%20help")

        #expect(connection.sentLines.isEmpty)
        await controller.disconnect()
    }

    @Test("malformed and nested command links are consumed locally")
    func invalidCommandLinksStayLocal() async throws {
        let connection = InMemoryConnection()
        let controller = SessionController(makeConnection: { connection })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("proteles-cmd://look")
        try await controller.send("proteles-cmd:///proteles-cmd%3A%2F%2F%2Flook")

        #expect(connection.sentLines.isEmpty)
        await controller.disconnect()
    }
}
