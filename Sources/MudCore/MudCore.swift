import Foundation
import Logging

/// Namespace for the platform-agnostic core of Proteles.
///
/// `MudCore` houses everything that does not depend on AppKit or UIKit:
/// networking, protocol parsers (Telnet, ANSI, MCCP, GMCP), scrollback,
/// session state, scripting, and plugin loading. The macOS and iOS app
/// targets each consume `MudCore` plus a thin platform-specific view layer.
public enum MudCore {
    /// Semantic version of this build. Bumped per release.
    public static let version = "0.0.2"

    /// Shared logger label root. Subsystems should derive child loggers,
    /// e.g. `Logger(label: "\(MudCore.loggerLabel).telnet")`.
    public static let loggerLabel = "com.proteles.MudCore"
}
