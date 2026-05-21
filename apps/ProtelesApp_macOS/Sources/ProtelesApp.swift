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
    /// Will become opt-in (off by default) ahead of 1.0.
    private let session = SessionController(
        autoRecord: true,
        reconnectPolicy: .standard
    )

    /// On-disk scrollback log under
    /// `~/Library/Application Support/com.proteles.ProtelesApp/`.
    private let persistence: ScrollbackPersistence?

    /// Profile collection + active-world selection, bridged to SwiftUI.
    @State private var worlds: WorldsModel

    init() {
        // Scrollback persistence.
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

        // Profile store → WorldsModel. defaultStoreURL only fails if
        // Application Support is unavailable (effectively never on
        // macOS); fall back to a temp file so the app still launches.
        let storeURL = (try? ProfileStore.defaultStoreURL())
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-profiles.json")
        _worlds = State(initialValue: WorldsModel(store: ProfileStore(url: storeURL)))

        if let persistence {
            let store = session.scrollbackStore
            Task { await persistence.attach(to: store) }
        }
    }

    var body: some Scene {
        WindowGroup("Proteles") {
            ContentView(session: session)
                .frame(minWidth: 800, minHeight: 500)
                .navigationTitle("Proteles")
                .task {
                    // Load profiles, then auto-connect if the active
                    // world is configured for it.
                    await worlds.load()
                    if let active = worlds.activeProfile, active.autoconnect {
                        try? await session.connect(
                            to: active.endpoint,
                            autologin: worlds.autologinPlan(for: active)
                        )
                    }
                }
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
            ProtelesCommands(session: session, worlds: worlds)
            CommandGroup(after: .pasteboard) {
                Button("Copy with Colour Codes") {
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

        Window("Worlds", id: ProtelesApp.worldsWindowID) {
            ConnectionManagerView(model: worlds) { profile in
                let session = session
                let worlds = worlds
                Task { @MainActor in
                    await worlds.setActive(profile.id)
                    let plan = worlds.autologinPlan(for: profile)
                    await session.disconnect()
                    try? await session.connect(to: profile.endpoint, autologin: plan)
                }
            }
            .frame(minWidth: 560, minHeight: 360)
        }
        .windowResizability(.contentSize)
    }

    static let worldsWindowID = "worlds"
}

/// Session + worlds commands, extracted so they can use
/// `@Environment(\.openWindow)` (which the `App` struct itself can't
/// hold) to surface the Worlds window.
private struct ProtelesCommands: Commands {
    let session: SessionController
    let worlds: WorldsModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Connect") {
                let session = session
                let worlds = worlds
                Task { @MainActor in
                    guard let active = worlds.activeProfile else { return }
                    try? await session.connect(
                        to: active.endpoint,
                        autologin: worlds.autologinPlan(for: active)
                    )
                }
            }
            .keyboardShortcut("K", modifiers: [.command])

            Button("Disconnect") {
                let session = session
                Task { await session.disconnect() }
            }
            .keyboardShortcut("D", modifiers: [.command, .shift])

            Divider()

            Button("Manage Worlds…") {
                openWindow(id: ProtelesApp.worldsWindowID)
            }
            .keyboardShortcut("M", modifiers: [.command, .shift])
        }
    }
}
