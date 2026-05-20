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

    /// Open the connection over TLS (`NWParameters.tls`) when true.
    public var useTLS: Bool

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

    /// Optional autologin descriptor. Credentials themselves live in
    /// the Keychain; this struct just names which Keychain item to use
    /// and what to send when prompted.
    public var autologin: Autologin?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16,
        useTLS: Bool = false,
        encoding: TextEncoding = .utf8,
        autoconnect: Bool = false,
        paletteOverride: ColorPalette? = nil,
        autologin: Autologin? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.encoding = encoding
        self.autoconnect = autoconnect
        self.paletteOverride = paletteOverride
        self.autologin = autologin
    }

    /// Convenience: produce the ``NetworkConnection/Endpoint`` this
    /// profile resolves to. Used at connect time so the SessionController
    /// doesn't need to know about profile semantics.
    public var endpoint: NetworkConnection.Endpoint {
        NetworkConnection.Endpoint(
            host: host,
            port: port,
            useTLS: useTLS
        )
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

    public enum ValidationIssue: Equatable, Sendable {
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
        useTLS: false,
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

/// Autologin recipe. Credentials live in Keychain — this struct names
/// the entry by Keychain account (typically `<profileID>.username`,
/// `<profileID>.password`) and lists which prompt patterns to look
/// for. Phase 3 ships the data shape; the trigger-driven sender
/// arrives in Phase 5 alongside the rest of the scripting engine
/// (PLAN.md §8.6).
public struct Autologin: Codable, Sendable, Equatable {
    /// Keychain account identifier for the username entry.
    public var usernameKeychainAccount: String

    /// Keychain account identifier for the password entry.
    public var passwordKeychainAccount: String

    /// Substring that, when seen in inbound text, triggers sending the
    /// username. Aardwolf's prompt is `"What be thy name, adventurer?"`.
    public var usernamePrompt: String

    /// Substring that triggers sending the password. Aardwolf's prompt
    /// is `"Password:"`.
    public var passwordPrompt: String

    public init(
        usernameKeychainAccount: String,
        passwordKeychainAccount: String,
        usernamePrompt: String,
        passwordPrompt: String
    ) {
        self.usernameKeychainAccount = usernameKeychainAccount
        self.passwordKeychainAccount = passwordKeychainAccount
        self.usernamePrompt = usernamePrompt
        self.passwordPrompt = passwordPrompt
    }
}
