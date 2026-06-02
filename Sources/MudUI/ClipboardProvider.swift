#if os(macOS)
    import AppKit
    import MudCore

    /// The app's clipboard provider for plugin `GetClipboard`/`SetClipboard`,
    /// backed by `NSPasteboard`. Both ops run on the main thread (AppKit) and
    /// return **synchronously** — the calling plugin's Lua blocks on the result,
    /// like the dialog provider. The command path that reaches a plugin is async,
    /// so the main thread is free to service the read/write; no deadlock.
    public func makeClipboardProvider() -> ClipboardProvider {
        ClipboardProvider(
            get: {
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { ClipboardAccess.read() }
                }
                return DispatchQueue.main.sync { MainActor.assumeIsolated { ClipboardAccess.read() } }
            },
            set: { text in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { ClipboardAccess.write(text) }
                } else {
                    DispatchQueue.main.sync { MainActor.assumeIsolated { ClipboardAccess.write(text) } }
                }
            }
        )
    }

    @MainActor
    private enum ClipboardAccess {
        static func read() -> String {
            NSPasteboard.general.string(forType: .string) ?? ""
        }

        static func write(_ text: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
#endif
