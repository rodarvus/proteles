import AppKit
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

    /// The captured ASCII "text map" (docked Text Map panel).
    @State private var asciiMap: MapModel

    /// The Search-and-Destroy panel model (docked S&D panel).
    @State private var snd = SnDPanelModel()

    /// Main-window tiled-dock layout (UI revamp — docs/UI_REVAMP.md).
    @State private var layout = LayoutStore()

    /// AppKit hooks for menu surgery the SwiftUI command API can't fully do
    /// (stripping the empty Format menu with deterministic timing).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                await scriptEngine.registerNativePlugin(AardGMCPHandler())
                await scriptEngine.registerNativePlugin(VitalShortcuts())
                await scriptEngine.registerNativePlugin(NoteMode())
                await scriptEngine.registerNativePlugin(TextSubstitution())
                await scriptEngine.registerNativePlugin(ChatEcho())
                await scriptEngine.registerNativePlugin(AsciiMap())
                await scriptEngine.registerNativePlugin(TickTimer())
                await scriptEngine.registerNativePlugin(URLLinkify())
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
        _asciiMap = State(initialValue: MapModel(store: session.mapStore))

        if let persistence {
            let store = session.scrollbackStore
            Task { await persistence.attach(to: store) }
        }

        // Single-session client: no window tabbing, so the "Show Tab Bar" /
        // "Show All Tabs" menu items don't clutter the menu bar.
        NSWindow.allowsAutomaticWindowTabbing = false
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
                asciiMap: asciiMap,
                snd: snd
            )
            .frame(minWidth: 940, minHeight: 500)
            .navigationTitle("Proteles")
        }
        .windowResizability(.contentSize)
        .commands {
            // Strip auto-generated menu items that don't apply to a MUD client:
            // the Format menu (rich-text styling), File ▸ New (no documents),
            // and the View ▸ Show/Customise Toolbar + sidebar commands.
            CommandGroup(replacing: .textFormatting) {}
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .help) {}

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
                Button("Copy as ANSI Colour Codes") {
                    NSApp.sendAction(#selector(MudTextView.copyWithCodes(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("C", modifiers: [.command, .shift])
                Button("Copy as Aardwolf Colour Codes") {
                    NSApp.sendAction(#selector(MudTextView.copyAsAardwolfCodes(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Copy as HTML") {
                    NSApp.sendAction(#selector(MudTextView.copyAsHTML(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .option])
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

        // Preferences (⌘,). SwiftUI adds the standard "Settings…" app-menu item.
        Settings {
            SettingsView()
        }

        // Detached panels: each torn-out panel gets its own window, keyed by
        // its kind so re-opening the same panel reuses one window.
        WindowGroup(for: PanelKind.self) { $kind in
            if let kind {
                DetachedPanelWindow(
                    kind: kind,
                    session: session,
                    layout: layout,
                    chat: chat,
                    map: map,
                    asciiMap: asciiMap,
                    snd: snd
                )
            }
        }
        .windowResizability(.contentSize)

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

/// Strips the empty "Format" menu AppKit leaves behind even after
/// `CommandGroup(replacing: .textFormatting) {}` — the editable command field
/// still contributes a Font/Text container. Done in the delegate so the timing
/// is deterministic (the main menu is fully built by
/// `applicationDidFinishLaunching`) and re-checked on activation so it can't
/// reappear if SwiftUI rebuilds the menu bar. A MUD client has no rich text.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        removeFormatMenu()
    }

    func applicationDidBecomeActive(_: Notification) {
        removeFormatMenu()
    }

    private func removeFormatMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let index = mainMenu.items.firstIndex(where: { $0.title == "Format" })
        else { return }
        mainMenu.removeItem(at: index)
    }
}

/// Session + worlds commands, extracted so they can use
/// `@Environment(\.openWindow)` (which the `App` struct itself can't
/// hold) to surface the Worlds window.
private struct ProtelesCommands: Commands {
    let session: SessionController
    let worlds: WorldsModel
    let scripts: ScriptsModel
    @Bindable var layout: LayoutStore
    @Environment(\.openWindow) private var openWindow
    /// Display preference, persisted in UserDefaults; ``ContentView`` mirrors
    /// the same key and pushes it to the session.
    @AppStorage("omitBlankLines") private var omitBlankLines = false
    /// Rich Exits: make room exits (incl. custom exits) clickable in the main
    /// output. Persisted in UserDefaults; ``ContentView`` pushes it to the session.
    @AppStorage("richExits") private var richExits = false

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
        }

        // Panels live in the main-window tiled dock (not separate windows, which
        // could fall behind the game window). Toggling shows/hides each in place.
        // Merge into the *existing* system View menu (which holds Enter Full
        // Screen) via `.sidebar` rather than a `CommandMenu("View")`, which would
        // create a second top-level View menu.
        CommandGroup(after: .sidebar) {
            Toggle(isOn: panelBinding(.map)) { Text("Map") }
                .keyboardShortcut("B", modifiers: [.command, .shift])
            Toggle(isOn: panelBinding(.asciiMap)) { Text("Text Map") }
                .keyboardShortcut("E", modifiers: [.command, .shift])
            Toggle(isOn: panelBinding(.channels)) { Text("Channels") }
                .keyboardShortcut("J", modifiers: [.command, .shift])
            Toggle(isOn: panelBinding(.hunt)) { Text("Search & Destroy") }
                .keyboardShortcut("U", modifiers: [.command, .shift])
            Toggle(isOn: panelBinding(.info)) { Text("Character") }
                .keyboardShortcut("I", modifiers: [.command, .shift])

            Divider()

            Button("Reset Layout") { layout.resetToDefault() }

            Divider()

            // Display preference (native equivalent of Omit_Blank_Lines): drop
            // completely-empty MUD lines from the main output. Persists via
            // @AppStorage; ContentView pushes the value to the session.
            Toggle("Omit Blank Lines", isOn: $omitBlankLines)

            // Make room exits (incl. custom exits) clickable in the main output
            // (native equivalent of Aardwolf-Rich-Exits, no miniwindow). Enabling
            // turns on Aardwolf's `tags exits` so the line is detectable.
            Toggle("Rich Exits", isOn: $richExits)
        }
    }

    /// A binding that reflects a panel's visibility and toggles it on change.
    private func panelBinding(_ kind: PanelKind) -> Binding<Bool> {
        Binding(get: { layout.isVisible(kind) }, set: { _ in layout.toggle(kind) })
    }
}
