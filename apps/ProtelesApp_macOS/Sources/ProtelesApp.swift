import MudCore
import MudOutputView_macOS
import MudUI
import SwiftUI

@main
struct ProtelesApp: App {
    /// App-level session. Phase 1 places this here so the chrome has a
    /// stable handle to bind to; in later phases the session lives
    /// inside a per-window owner along with profile metadata.
    ///
    /// `autoRecord: true` during development — every connect captures
    /// a fully-replayable session to
    /// `~/Library/Application Support/com.proteles.ProtelesApp/recordings/`.
    /// Will become opt-in (off by default) ahead of 1.0; users will
    /// enable it via Preferences when they want to capture for bug
    /// reports.
    private let session = SessionController(autoRecord: true)

    /// On-disk scrollback log. Lives at
    /// `~/Library/Application Support/com.proteles.ProtelesApp/scrollback.sqlite`
    /// and is appended to as long as the app is running. Phase 3 will
    /// likely partition by profile.
    private let persistence: ScrollbackPersistence?

    init() {
        let persistence: ScrollbackPersistence?
        do {
            let location = try ScrollbackDatabase.defaultLocation()
            let database = try ScrollbackDatabase(url: location)
            persistence = ScrollbackPersistence(database: database)
        } catch {
            NSLog("[Proteles] persistence init failed: \(error)")
            persistence = nil
        }
        self.persistence = persistence

        if let persistence {
            let store = session.scrollbackStore
            Task {
                await persistence.attach(to: store)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Proteles") {
            ContentView(session: session)
                .frame(minWidth: 800, minHeight: 500)
                .navigationTitle("Proteles")
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Proteles") {
                    NSApp.orderFrontStandardAboutPanel(
                        options: [
                            .applicationVersion: MudCore.version,
                            .credits: NSAttributedString(
                                string: "A native Aardwolf MUD client for macOS.",
                                attributes: [.font: NSFont.systemFont(ofSize: 11)]
                            )
                        ]
                    )
                }
            }
            CommandGroup(after: .newItem) {
                Button("Connect to Aardwolf") {
                    let session = session
                    Task {
                        try? await session.connect(
                            to: .init(host: "aardmud.org", port: 4000)
                        )
                    }
                }
                .keyboardShortcut("K", modifiers: [.command])

                Button("Disconnect") {
                    let session = session
                    Task {
                        await session.disconnect()
                    }
                }
                .keyboardShortcut("D", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy with Colour Codes") {
                    // The action is dispatched through the responder
                    // chain so whichever MudTextView is first responder
                    // gets the call. `to: nil` is the standard pattern.
                    NSApp.sendAction(
                        #selector(MudTextView.copyWithCodes(_:)),
                        to: nil,
                        from: nil
                    )
                }
                .keyboardShortcut("C", modifiers: [.command, .shift])
            }
            CommandMenu("Debug") {
                Button("Start Recording") {
                    let session = session
                    Task {
                        do {
                            let url = try SessionRecorder.defaultRecordingURL()
                            try await session.startRecording(to: url)
                            NSLog("[Proteles] recording to \(url.path)")
                        } catch {
                            NSLog("[Proteles] start recording failed: \(error)")
                        }
                    }
                }
                Button("Stop Recording") {
                    let session = session
                    Task {
                        await session.stopRecording()
                        NSLog("[Proteles] recording stopped")
                    }
                }
            }
        }
    }
}
