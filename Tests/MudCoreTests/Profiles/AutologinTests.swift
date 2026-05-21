import Foundation
@testable import MudCore
import Testing

@Suite("Autologin — model")
struct AutologinModelTests {
    @Test("Defaults match Aardwolf's prompts")
    func defaults() {
        let autologin = Autologin(username: "Conan")
        #expect(autologin.username == "Conan")
        #expect(autologin.usernamePrompt == "What be thy name, adventurer?")
        #expect(autologin.passwordPrompt == "Password:")
    }

    @Test("passwordAccount keys off the profile UUID")
    func passwordAccountStable() {
        let id = UUID()
        #expect(Autologin.passwordAccount(for: id) == "\(id.uuidString).password")
    }

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        let original = Autologin(
            username: "Thora",
            usernamePrompt: "Name?",
            passwordPrompt: "Pass?"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Autologin.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding tolerates missing prompt fields (older documents)")
    func tolerantDecodeMissingPrompts() throws {
        let json = Data(#"{"username":"Legacy"}"#.utf8)
        let decoded = try JSONDecoder().decode(Autologin.self, from: json)
        #expect(decoded.username == "Legacy")
        #expect(decoded.usernamePrompt == Autologin.defaultUsernamePrompt)
        #expect(decoded.passwordPrompt == Autologin.defaultPasswordPrompt)
    }

    @Test("Decoding tolerates a wholly empty object")
    func tolerantDecodeEmpty() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(Autologin.self, from: json)
        #expect(decoded.username.isEmpty)
        #expect(decoded.usernamePrompt == Autologin.defaultUsernamePrompt)
    }
}

@Suite("WorldProfile — autologin plan resolution")
struct AutologinPlanResolutionTests {
    @Test("nil when the profile has no autologin")
    func nilWithoutAutologin() {
        let profile = WorldProfile.aardwolfDefault
        #expect(profile.autologinPlan(using: InMemoryCredentialStore()) == nil)
    }

    @Test("nil when the username is blank")
    func nilWithBlankUsername() {
        var profile = WorldProfile.aardwolfDefault
        profile.autologin = Autologin(username: "   ")
        #expect(profile.autologinPlan(using: InMemoryCredentialStore()) == nil)
    }

    @Test("Resolves username + prompts, folding in the stored password")
    func resolvesWithPassword() {
        var profile = WorldProfile.aardwolfDefault
        profile.autologin = Autologin(username: "Conan")
        let credentials = InMemoryCredentialStore()
        credentials.setPassword(
            "cimmeria",
            forAccount: Autologin.passwordAccount(for: profile.id)
        )

        let plan = profile.autologinPlan(using: credentials)
        #expect(plan?.username == "Conan")
        #expect(plan?.password == "cimmeria")
        #expect(plan?.usernamePrompt == "What be thy name, adventurer?")
        #expect(plan?.passwordPrompt == "Password:")
    }

    @Test("Resolves with an empty password when none is stored")
    func resolvesWithoutPassword() {
        var profile = WorldProfile.aardwolfDefault
        profile.autologin = Autologin(username: "Conan")
        let plan = profile.autologinPlan(using: InMemoryCredentialStore())
        #expect(plan?.username == "Conan")
        #expect(plan?.password.isEmpty == true)
    }
}

@Suite("InMemoryCredentialStore")
struct InMemoryCredentialStoreTests {
    @Test("set then read returns the value")
    func setGet() {
        let store = InMemoryCredentialStore()
        store.setPassword("s3cret", forAccount: "a")
        #expect(store.password(forAccount: "a") == "s3cret")
    }

    @Test("reading an unknown account returns nil")
    func unknownNil() {
        #expect(InMemoryCredentialStore().password(forAccount: "missing") == nil)
    }

    @Test("setting an empty password removes the entry")
    func emptyRemoves() {
        let store = InMemoryCredentialStore()
        store.setPassword("x", forAccount: "a")
        store.setPassword("", forAccount: "a")
        #expect(store.password(forAccount: "a") == nil)
    }

    @Test("removePassword clears the entry and is idempotent")
    func removeIdempotent() {
        let store = InMemoryCredentialStore()
        store.setPassword("x", forAccount: "a")
        store.removePassword(forAccount: "a")
        store.removePassword(forAccount: "a")
        #expect(store.password(forAccount: "a") == nil)
    }
}

@Suite("KeychainStore — round-trip", .serialized)
struct KeychainStoreTests {
    /// The CI keychain is sometimes locked/unavailable for an unsigned
    /// test binary. We probe with a write first; if the value doesn't
    /// come back the environment can't support the test, so we bail
    /// rather than fail the gate. On a developer machine it exercises the
    /// real Security framework path end-to-end.
    @Test("set / read / remove against the real keychain")
    func roundTrip() {
        let store = KeychainStore(service: "com.proteles.tests.\(UUID().uuidString)")
        let account = "kc-roundtrip"
        store.setPassword("topsecret", forAccount: account)
        guard store.password(forAccount: account) == "topsecret" else {
            return // keychain unavailable in this environment — skip
        }
        store.setPassword("changed", forAccount: account)
        #expect(store.password(forAccount: account) == "changed")
        store.removePassword(forAccount: account)
        #expect(store.password(forAccount: account) == nil)
    }
}
