import Foundation

/// App-provided hook to read/write the system clipboard for plugins
/// (MUSHclient's `GetClipboard`/`SetClipboard`). MudCore is platform-agnostic,
/// so the macOS app injects an `NSPasteboard`-backed provider via
/// ``ScriptEngine/setClipboardProvider(_:)`` — exactly like the dialog provider.
/// With no provider (headless runs, tests) clipboard access degrades safely:
/// `get` yields `""` and `set` is a no-op.
///
/// Both closures are called **synchronously** from the script executor, so an
/// `AppKit`-backed implementation must hop to the main thread itself (see the
/// app's `makeClipboardProvider()`), mirroring the dialog provider.
public struct ClipboardProvider: Sendable {
    public let get: @Sendable () -> String
    public let set: @Sendable (String) -> Void

    public init(get: @escaping @Sendable () -> String, set: @escaping @Sendable (String) -> Void) {
        self.get = get
        self.set = set
    }
}
