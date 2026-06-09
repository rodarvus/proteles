import Foundation
@testable import MudCore
import Testing

@Suite("WorldProfile — transport field (#ws)")
struct WorldProfileTransportTests {
    @Test("a profile saved before the transport field decodes as .direct")
    func legacyDecodesDirect() throws {
        let json = """
        {"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","name":"Aardwolf",
         "host":"aardmud.org","port":4000,"encoding":"utf8","autoconnect":false}
        """
        let profile = try JSONDecoder().decode(WorldProfile.self, from: Data(json.utf8))
        #expect(profile.transport == .direct)
    }

    @Test("transport round-trips through Codable")
    func roundTrips() throws {
        let profile = WorldProfile(name: "Test", host: "aardmud.net", port: 6555, transport: .webSocket)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(WorldProfile.self, from: data)
        #expect(decoded.transport == .webSocket)
    }
}
