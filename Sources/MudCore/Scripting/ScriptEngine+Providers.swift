import Foundation

/// App-provided I/O hooks the script engine forwards to its runtime. These are
/// platform bridges the macOS app injects at launch; with neither set, the
/// corresponding plugin calls degrade safely.
public extension ScriptEngine {
    /// Install the app's `utils.*` dialog provider (native modals; `nil` = no-op).
    func setDialogProvider(_ provider: ScriptDialogProvider?) async {
        await runtime.setDialogProvider(provider)
    }

    /// Install the app's clipboard provider (`GetClipboard`/`SetClipboard`;
    /// `nil` = "" / no-op).
    func setClipboardProvider(_ provider: ClipboardProvider?) async {
        await runtime.setClipboardProvider(provider)
    }

    /// Install the synchronous `WindowMenu` provider (`nil` = cancelled menu).
    func setMiniWindowMenuProvider(_ provider: MiniWindowMenuProvider?) async {
        await runtime.setMiniWindowMenuProvider(provider)
    }
}
