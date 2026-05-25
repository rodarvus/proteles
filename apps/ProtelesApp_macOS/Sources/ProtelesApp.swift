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
    private let session: SessionController

    /// The shared scripting engine (triggers/aliases/timers/Lua), wired into
    /// the session. `nil` only if the Lua runtime failed to initialise.
    private let scriptEngine: ScriptEngine?

    /// On-disk scrollback log under
    /// `~/Library/Application Support/com.proteles.ProtelesApp/`.
    private let persistence: ScrollbackPersistence?

    /// Profile collection + active-world selection, bridged to SwiftUI.
    @State private var worlds: WorldsModel

    /// Captured chat (`comm.channel`), bridged to SwiftUI.
    @State private var chat: ChatModel

    /// The active world's triggers/aliases/timers, bridged to SwiftUI and
    /// kept in sync with the live session.
    @State private var scripts: ScriptsModel

    /// The active world's installed MUSHclient plugins (Plugins window).
    @State private var plugins: PluginsModel

    /// The graphical GMCP map (docked Map panel).
    @State private var map: MapPanelModel

    /// The Search-and-Destroy panel model (docked S&D panel).
    @State private var snd = SnDPanelModel()

    /// Main-window dock layout (which live panel is shown).
    @State private var layout = LayoutModel()

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

        // Scripting engine → session. A failed Lua init disables scripting
        // but must not stop the app launching.
        let scriptEngine = try? ScriptEngine()
        self.scriptEngine = scriptEngine
        session = SessionController(
            scriptEngine: scriptEngine,
            autoRecord: true,
            reconnectPolicy: .standard
        )

        // Register the built-in native plugins (ported from the Aardwolf
        // package). Registration is quick and completes well before connect.
        if let scriptEngine {
            Task {
                await scriptEngine.registerNativePlugin(VitalShortcuts())
                await scriptEngine.registerNativePlugin(NoteMode())
                await scriptEngine.registerNativePlugin(TextSubstitution())
                await scriptEngine.registerNativePlugin(ChatEcho())
                await scriptEngine.registerNativePlugin(AsciiMap())
            }
        }

        // Profile store → WorldsModel. defaultStoreURL only fails if
        // Application Support is unavailable (effectively never on
        // macOS); fall back to a temp file so the app still launches.
        let storeURL = (try? ProfileStore.defaultStoreURL())
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-profiles.json")
        _worlds = State(initialValue: WorldsModel(store: ProfileStore(url: storeURL)))
        _chat = State(initialValue: ChatModel(store: session.chatStore))
        _scripts = State(initialValue: ScriptsModel(session: session))
        _plugins = State(initialValue: PluginsModel(session: session))
        _map = State(initialValue: MapPanelModel(session: session))

        if let persistence {
            let store = session.scrollbackStore
            Task { await persistence.attach(to: store) }
        }
    }

    var body: some Scene {
        WindowGroup("Proteles") {
            ContentView(
                session: session,
                worlds: worlds,
                scripts: scripts,
                layout: layout,
                chat: chat,
                map: map,
                snd: snd
            )
            .frame(minWidth: 940, minHeight: 500)
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
            ProtelesCommands(session: session, worlds: worlds, scripts: scripts, layout: layout)
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
            CommandMenu("Databases") {
                Button("Import Map Database…") { map.importDatabase() }
                Button("Import Search & Destroy Database…") { snd.requestImport() }
                Divider()
                Menu("Reset Databases (Testing)") {
                    Button("Empty Map Database…") { map.resetDatabase() }
                    Button("Empty Search & Destroy Database…") { snd.requestReset() }
                }
            }
        }

        Window("Worlds", id: ProtelesApp.worldsWindowID) {
            ConnectionManagerView(model: worlds) { profile in
                let session = session
                let worlds = worlds
                let scripts = scripts
                Task { @MainActor in
                    await worlds.setActive(profile.id)
                    let plan = worlds.autologinPlan(for: profile)
                    await session.disconnect()
                    await scripts.load(forProfile: profile.id)
                    try? await session.connect(to: profile.endpoint, autologin: plan)
                }
            }
            .frame(minWidth: 560, minHeight: 360)
        }
        .windowResizability(.contentSize)

        Window("Scripts", id: ProtelesApp.scriptsWindowID) {
            ScriptsView(model: scripts)
        }
        .windowResizability(.contentSize)

        Window("Plugins", id: ProtelesApp.pluginsWindowID) {
            PluginsView(model: plugins)
                .task(id: worlds.activeProfileID) {
                    guard let id = worlds.activeProfileID,
                          let directory = MUSHclientPluginLoader.defaultDirectory(forProfile: id)
                    else { return }
                    let scripts = scripts
                    plugins.prepare(directory: directory) {
                        await scripts.load(forProfile: id)
                    }
                    await plugins.refreshNative()
                }
        }
        .windowResizability(.contentSize)
    }

    static let worldsWindowID = "worlds"
    static let scriptsWindowID = "scripts"
    static let pluginsWindowID = "plugins"
}

/// Session + worlds commands, extracted so they can use
/// `@Environment(\.openWindow)` (which the `App` struct itself can't
/// hold) to surface the Worlds window.
private struct ProtelesCommands: Commands {
    let session: SessionController
    let worlds: WorldsModel
    let scripts: ScriptsModel
    @Bindable var layout: LayoutModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Connect") {
                let session = session
                let worlds = worlds
                let scripts = scripts
                Task { @MainActor in
                    guard let active = worlds.activeProfile else { return }
                    await scripts.load(forProfile: active.id)
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

            Button("Scripts…") {
                openWindow(id: ProtelesApp.scriptsWindowID)
            }
            .keyboardShortcut("T", modifiers: [.command, .shift])

            Button("Plugins…") {
                openWindow(id: ProtelesApp.pluginsWindowID)
            }
            .keyboardShortcut("P", modifiers: [.command, .shift])

            Divider()

            // Live panels live in the main-window dock (not separate windows,
            // which could fall behind the game window).
            Button("Info Panel") { layout.show(.info) }
                .keyboardShortcut("I", modifiers: [.command, .shift])
            Button("Map Panel") { layout.show(.map) }
                .keyboardShortcut("B", modifiers: [.command, .shift])
            Button("Chat Panel") { layout.show(.chat) }
                .keyboardShortcut("J", modifiers: [.command, .shift])
        }
    }
}
