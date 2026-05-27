import Foundation
import Logging

/// Namespace for the platform-agnostic core of Proteles.
///
/// `MudCore` houses everything that does not depend on AppKit or UIKit:
/// networking, protocol parsers (Telnet, ANSI, MCCP, GMCP), scrollback,
/// session state, scripting, and plugin loading. The macOS and iOS app
/// targets each consume `MudCore` plus a thin platform-specific view layer.
public enum MudCore {
    /// Marketing version of this build, read from the app bundle's
    /// `CFBundleShortVersionString` so there's a single source of truth (set in
    /// `apps/ProtelesApp_macOS/project.yml`, propagated to Info.plist by
    /// xcodegen). Feeds the About panel and the GMCP client-version handshake,
    /// so they can't drift from the shipped version again. Falls back to
    /// `"0.0.0"` outside an app bundle (e.g. `swift test`).
    public static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    /// Shared logger label root. Subsystems should derive child loggers,
    /// e.g. `Logger(label: "\(MudCore.loggerLabel).telnet")`.
    public static let loggerLabel = "com.proteles.MudCore"
}
