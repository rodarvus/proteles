import Foundation
@testable import MudCore
import Testing

@Suite("WorldProfile — defaults and identity")
struct WorldProfileBasicsTests {
    @Test("aardwolfDefault points at the canonical Aardwolf endpoint")
    func aardwolfDefaultEndpoint() {
        let profile = WorldProfile.aardwolfDefault
        #expect(profile.name == "Aardwolf")
        #expect(profile.host == "aardmud.org")
        #expect(profile.port == 23)
        #expect(WorldProfile.knownAardwolfPorts.first == 23)
        #expect(profile.encoding == .utf8)
        #expect(!profile.autoconnect)
        #expect(profile.autologin == nil)
    }

    @Test("Profiles initialised with explicit UUIDs are Equatable by content")
    func equatableByContent() {
        let id = UUID()
        let lhs = WorldProfile(id: id, name: "Test", host: "h", port: 1)
        let rhs = WorldProfile(id: id, name: "Test", host: "h", port: 1)
        #expect(lhs == rhs)
    }

    @Test("endpoint mirrors profile fields onto NetworkConnection.Endpoint")
    func endpointMirroring() {
        let profile = WorldProfile(
            name: "X",
            host: "example.com",
            port: 4040
        )
        #expect(profile.endpoint.host == "example.com")
        #expect(profile.endpoint.port == 4040)
    }
}

@Suite("WorldProfile — validation")
struct WorldProfileValidationTests {
    @Test("Well-formed profile has no validation issues")
    func validProfile() {
        let profile = WorldProfile.aardwolfDefault
        #expect(profile.validate().isEmpty)
    }

    @Test("Empty name flagged")
    func emptyNameFlagged() {
        var profile = WorldProfile.aardwolfDefault
        profile.name = "   "
        #expect(profile.validate().contains(.emptyName))
    }

    @Test("Empty host flagged")
    func emptyHostFlagged() {
        var profile = WorldProfile.aardwolfDefault
        profile.host = ""
        #expect(profile.validate().contains(.emptyHost))
    }

    @Test("Port 0 flagged")
    func portZeroFlagged() {
        var profile = WorldProfile.aardwolfDefault
        profile.port = 0
        #expect(profile.validate().contains(.invalidPort))
    }

    @Test("Multiple issues surface together")
    func multipleIssues() {
        let profile = WorldProfile(
            name: "",
            host: "",
            port: 0
        )
        let issues = profile.validate()
        #expect(issues.contains(.emptyName))
        #expect(issues.contains(.emptyHost))
        #expect(issues.contains(.invalidPort))
    }
}

@Suite("WorldProfile — JSON Codable round-trip")
struct WorldProfileCodableTests {
    @Test("Minimal profile round-trips byte-identically")
    func minimalProfileRoundTrip() throws {
        let id = UUID()
        let original = WorldProfile(
            id: id,
            name: "Aardwolf",
            host: "aardmud.org",
            port: 4000
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(WorldProfile.self, from: data)
        #expect(decoded == original)
    }

    @Test("Profile with autologin round-trips")
    func profileWithAutologinRoundTrip() throws {
        let id = UUID()
        let autologin = Autologin(
            username: "Conan",
            usernamePrompt: "What be thy name, adventurer?",
            passwordPrompt: "Password:"
        )
        let original = WorldProfile(
            id: id,
            name: "Aardwolf",
            host: "aardmud.org",
            port: 4040,
            encoding: .utf8,
            autoconnect: true,
            paletteOverride: nil,
            autologin: autologin
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorldProfile.self, from: data)
        #expect(decoded == original)
    }

    @Test("Profile with palette override round-trips")
    func profileWithPaletteOverrideRoundTrip() throws {
        let original = WorldProfile(
            id: UUID(),
            name: "Themed",
            host: "h",
            port: 1,
            paletteOverride: .xtermDefault
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorldProfile.self, from: data)
        #expect(decoded == original)
    }
}
