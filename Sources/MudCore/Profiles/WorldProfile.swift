import Foundation

/// User-editable description of a MUD to connect to (PLAN.md §8.4).
///
/// Phase 3 establishes the data model; the Connection Manager UI lands
/// alongside in MudUI, and the app rewires its **Connect to Aardwolf**
/// menu item from a hardcoded endpoint to "connect to the active
/// profile".
///
/// `Codable + Sendable + Identifiable` — profiles serialise to JSON
/// under `~/Library/Application Support/com.proteles.ProtelesApp/profiles/`
/// (the on-disk store is its own type, landing in a follow-up commit).
public struct WorldProfile: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity for a profile. Survives renames and edits; tests
    /// can inject a known value.
    public let id: UUID

    /// Human-readable name shown in the Connection Manager.
    public var name: String

    /// Hostname or IP address. Treated as a literal — no DNS work here;
    /// `NWConnection` handles resolution at connect time.
    public var host: String

    /// TCP port, 1…65535. Validated at connect time by
    /// ``NetworkConnection``.
    public var port: UInt16

    /// Wire encoding for inbound bytes. ANSI / MUD output is almost
    /// always UTF-8 these days; legacy worlds may still ship Latin-1.
    public var encoding: TextEncoding

    /// When true, the app attempts to ``SessionController/connect(to:)``
    /// to this profile on launch / when it becomes the active profile.
    public var autoconnect: Bool

    /// Optional palette override. `nil` means "use the application
    /// default" (currently ``ColorPalette/xtermDefault``).
    ///
    /// Profiles inherit the global default until the user explicitly
    /// chooses a per-world palette in Preferences (Phase 7).
    public var paletteOverride: ColorPalette?

    /// Optional autologin descriptor. The username and prompt patterns
    /// live here (the username is not secret); the matching password is
    /// stored separately in a ``CredentialStore`` under
    /// ``Autologin/passwordAccount(for:)``.
    public var autologin: Autologin?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16,
        encoding: TextEncoding = .utf8,
        autoconnect: Bool = false,
        paletteOverride: ColorPalette? = nil,
        autologin: Autologin? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.encoding = encoding
        self.autoconnect = autoconnect
        self.paletteOverride = paletteOverride
        self.autologin = autologin
    }

    /// Convenience: produce the ``NetworkConnection/Endpoint`` this
    /// profile resolves to. Used at connect time so the SessionController
    /// doesn't need to know about profile semantics.
    public var endpoint: NetworkConnection.Endpoint {
        NetworkConnection.Endpoint(host: host, port: port)
    }

    /// Validate fields a user could realistically get wrong in the
    /// Connection Manager. Returned as an array so the UI can surface
    /// multiple issues at once.
    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            issues.append(.emptyName)
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            issues.append(.emptyHost)
        }
        if port == 0 {
            issues.append(.invalidPort)
        }
        return issues
    }

    public enum ValidationIssue: Equatable, Hashable, Sendable {
        case emptyName
        case emptyHost
        case invalidPort
    }
}

public extension WorldProfile {
    /// The starter profile every fresh install gets: plaintext Aardwolf
    /// on the canonical public port. UI surfaces it as **Aardwolf**.
    static let aardwolfDefault = WorldProfile(
        name: "Aardwolf",
        host: "aardmud.org",
        port: 4000,
        encoding: .utf8,
        autoconnect: false
    )
}

/// Inbound byte encoding. UTF-8 is the universal modern default;
/// Latin-1 covers a few legacy worlds.
public enum TextEncoding: String, Codable, Sendable, Equatable, CaseIterable {
    case utf8
    case latin1
}

/// Autologin recipe stored in the profile document.
///
/// "Diku-style" (MushClient's term) prompt-driven login: after
/// connecting, the session watches inbound text for ``usernamePrompt``
/// and sends ``username``, then waits for ``passwordPrompt`` and sends
/// the password. The username is not secret and lives here in
/// `profiles.json`; the password is stored separately in a
/// ``CredentialStore`` (the Keychain in the app) under
/// ``passwordAccount(for:)``.
///
/// The prompt strings default to Aardwolf's, but are overridable so the
/// same machinery can serve other Diku-derived worlds later.
public struct Autologin: Codable, Sendable, Equatable {
    /// Sent verbatim (followed by a line terminator) when
    /// ``usernamePrompt`` is seen.
    public var username: String

    /// Substring that, when seen in inbound text, triggers sending the
    /// username. Defaults to Aardwolf's `"What be thy name, adventurer?"`.
    public var usernamePrompt: String

    /// Substring that triggers sending the password. Defaults to
    /// Aardwolf's `"Password:"`.
    public var passwordPrompt: String

    public init(
        username: String,
        usernamePrompt: String = Autologin.defaultUsernamePrompt,
        passwordPrompt: String = Autologin.defaultPasswordPrompt
    ) {
        self.username = username
        self.usernamePrompt = usernamePrompt
        self.passwordPrompt = passwordPrompt
    }

    public static let defaultUsernamePrompt = "What be thy name, adventurer?"
    public static let defaultPasswordPrompt = "Password:"

    /// The ``CredentialStore`` account string for a profile's password.
    /// Stable across edits because it keys off the profile's UUID.
    public static func passwordAccount(for profileID: WorldProfile.ID) -> String {
        "\(profileID.uuidString).password"
    }

    /// Decoding tolerates older documents that omitted the prompt fields
    /// (or, pre-rework, stored Keychain account names we no longer use).
    private enum CodingKeys: String, CodingKey {
        case username
        case usernamePrompt
        case passwordPrompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        usernamePrompt = try container.decodeIfPresent(String.self, forKey: .usernamePrompt)
            ?? Autologin.defaultUsernamePrompt
        passwordPrompt = try container.decodeIfPresent(String.self, forKey: .passwordPrompt)
            ?? Autologin.defaultPasswordPrompt
    }
}

/// A fully-resolved autologin instruction handed to
/// ``SessionController/connect(to:autologin:)``. Unlike ``Autologin`` it
/// carries the actual password (already fetched from the
/// ``CredentialStore``), so MudCore networking never depends on the
/// Security framework and the prompt-driven state machine is trivially
/// testable with plain values.
public struct AutologinPlan: Sendable, Equatable {
    public var username: String
    public var password: String
    public var usernamePrompt: String
    public var passwordPrompt: String

    public init(
        username: String,
        password: String,
        usernamePrompt: String = Autologin.defaultUsernamePrompt,
        passwordPrompt: String = Autologin.defaultPasswordPrompt
    ) {
        self.username = username
        self.password = password
        self.usernamePrompt = usernamePrompt
        self.passwordPrompt = passwordPrompt
    }
}

public extension WorldProfile {
    /// Resolve this profile's ``AutologinPlan`` by combining its
    /// ``autologin`` descriptor with the password fetched from
    /// `credentials`. Returns `nil` when autologin is not configured or
    /// the username is blank (nothing to send).
    func autologinPlan(using credentials: some CredentialStore) -> AutologinPlan? {
        guard let autologin else { return nil }
        let username = autologin.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return nil }
        let password = credentials.password(forAccount: Autologin.passwordAccount(for: id)) ?? ""
        return AutologinPlan(
            username: autologin.username,
            password: password,
            usernamePrompt: autologin.usernamePrompt,
            passwordPrompt: autologin.passwordPrompt
        )
    }
}
