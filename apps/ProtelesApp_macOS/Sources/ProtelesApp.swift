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

    /// Picks the connection transport (Direct TCP vs Aardwolf's WebSocket
    /// gateway) per the active world; kept in sync by ``WorldsModel`` and read by
    /// the session's `makeConnection` factory (#ws).
    private let transportSelector = TransportSelector()

    /// The shared scripting engine (triggers/aliases/timers/Lua), wired into
    /// the session. `nil` only if the Lua runtime failed to initialise.
    private let scriptEngine: ScriptEngine?

    /// On-disk scrollback log under
    /// `~/Library/Application Support/com.proteles.ProtelesApp/`.
    private let persistence: ScrollbackPersistence?

    /// Session-resume (#42): the breadcrumb store, and the fresh token consumed
    /// at launch (non-nil only when the last run was connected and the process
    /// just restarted — Sparkle update, crash, or quick relaunch).
    private let resumeStore: ResumeTokenStore?
    private let resumeToken: ResumeToken?

    /// Sparkle auto-updater (#23). Started at launch; drives the "Check for
    /// Updates…" menu item and background checks.
    @StateObject private var updater = Updater()

    /// Profile collection + active-world selection, bridged to SwiftUI.
    @State var worlds: WorldsModel

    /// Captured chat (`comm.channel`), bridged to SwiftUI.
    @State private var chat: ChatModel

    /// The active world's triggers/aliases/timers, bridged to SwiftUI and
    /// kept in sync with the live session.
    @State private var scripts: ScriptsModel

    /// The active world's installed MUSHclient plugins (Plugins window).
    @State private var plugins: PluginsModel

    /// Script diagnostics + REPL (Lua Console window).
    @State private var luaConsole: LuaConsoleModel

    /// The graphical GMCP map (docked Map panel).
    @State private var map: MapPanelModel

    /// The captured ASCII "text map" (docked Text Map panel).
    @State private var asciiMap: MapModel

    /// The Search-and-Destroy panel model (docked S&D panel).
    @State private var snd = SnDPanelModel()

    /// Main-window tiled-dock layout (UI revamp — docs/UI_REVAMP.md).
    @State private var layout = LayoutStore()

    /// In-game Help panel model (shared by the docked + detached Help views).
    @State private var help = HelpPanelModel()
    @State private var levels = LevelDBPanelModel()
    /// MUSHclient import flow (File ▸ Import from MUSHclient…).
    @State var importModel = MUSHclientImportModel()
    @State private var pluginDBs = PluginDatabasesModel()

    /// AppKit hooks for menu surgery the SwiftUI command API can't fully do
    /// (stripping the empty Format menu with deterministic timing).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Import hand-editable preferences (Settings/preferences.json) into
        // UserDefaults before any @AppStorage view reads them, then mirror
        // changes back (#43).
        PreferencesFile.shared.start()

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
            reconnectPolicy: .standard,
            logFileURL: { format in ProtelesApp.makeLogURL(format: format) },
            makeConnection: { [transportSelector] in transportSelector.makeConnection() }
        )

        // Register the built-in native plugins (ported from the Aardwolf
        // package). Registration is quick and completes well before connect.
        if let scriptEngine { Self.registerNativePlugins(on: scriptEngine) }

        // Profile store → WorldsModel. defaultStoreURL only fails if
        // Application Support is unavailable (effectively never on
        // macOS); fall back to a temp file so the app still launches.
        let storeURL = (try? ProfileStore.defaultStoreURL())
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-profiles.json")
        _worlds = State(initialValue: WorldsModel(
            store: ProfileStore(url: storeURL),
            transportSelector: transportSelector
        ))
        _chat = State(initialValue: ChatModel(store: session.chatStore))
        _scripts = State(initialValue: ScriptsModel(session: session))
        _plugins = State(initialValue: PluginsModel(session: session))
        _luaConsole = State(initialValue: LuaConsoleModel(session: session))
        _map = State(initialValue: MapPanelModel(session: session))
        _asciiMap = State(initialValue: MapModel(store: session.mapStore))

        // Session resume (#42): consume the breadcrumb and, when resuming,
        // restore scrollback before persistence attaches (see
        // ProtelesApp+Resume.swift), then attach persistence for the new session.
        let resumed = ProtelesApp.resumeOnLaunch(
            persistence: persistence,
            store: session.scrollbackStore
        )
        resumeStore = resumed.store
        resumeToken = resumed.token
        ProtelesApp.wireResumeClear(session: session, store: resumed.store)

        // Single-session client: no window tabbing, so the "Show Tab Bar" /
        // "Show All Tabs" menu items don't clutter the menu bar.
        NSWindow.allowsAutomaticWindowTabbing = false

        Self.wireTerminationSave(session: session)

        // Opt-in crash/hang diagnostics (MetricKit): subscribe iff the user has
        // enabled it. MetricKit delivers any pending payload shortly after launch.
        #if canImport(MetricKit)
            DiagnosticsController.shared.setEnabled(
                UserDefaults.standard.bool(forKey: DiagnosticsController.enabledKey)
            )
        #endif
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
                snd: snd,
                help: help,
                levels: levels,
                pluginDBs: pluginDBs,
                resumeStore: resumeStore,
                resumeToken: resumeToken,
                updater: updater
            )
            .frame(minWidth: 940, minHeight: 500)
            .navigationTitle("Proteles")
            .sheet(isPresented: importSheetBinding) { MUSHclientImportSheet(model: importModel) }
        }
        .windowResizability(.contentSize)
        .commands {
            // Strip auto-generated menu items that don't apply to a MUD client:
            // the Format menu (rich-text styling), File ▸ New (no documents),
            // and the View ▸ Show/Customise Toolbar + sidebar commands.
            CommandGroup(replacing: .textFormatting) {}
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .help) {}

            CommandGroup(replacing: .appInfo) {
                Button("About Proteles") {
                    NSApp.orderFrontStandardAboutPanel(
                        options: [
                            .applicationVersion: MudCore.version,
                            .credits: Self.aboutCredits
                        ]
                    )
                }
                Divider()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            ProtelesCommands(
                session: session,
                worlds: worlds,
                scripts: scripts,
                layout: layout,
                resumeStore: resumeStore,
                importFromMUSHclient: presentMUSHclientImport
            )
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
            // Debug + Databases menus moved to Settings ▸ Development (the
            // user's call: dev/maintenance tools, not daily-play commands).
        }

        // Preferences (⌘,). SwiftUI adds the standard "Settings…" app-menu item.
        Settings {
            SettingsView(session: session, map: map, snd: snd, pluginDBs: pluginDBs)
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
                    snd: snd,
                    help: help,
                    levels: levels,
                    scripts: scripts
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
                    ProtelesApp.logContext.worldName = profile.name
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

        // In-game Help reader: a dedicated, normal-level window (not a dock
        // tile, not a floating panel). Auto-opened by ContentView when a help
        // article is captured; width-capped (~90 chars) since help is
        // pre-wrapped at ~76 columns.
        Window("Help", id: ProtelesApp.helpWindowID) {
            HelpPanelView(model: help)
                .frame(minWidth: 520, idealWidth: 740, maxWidth: 820, minHeight: 380, maxHeight: .infinity)
                .navigationTitle("Help")
        }
        .defaultSize(width: 740, height: 640)
        .windowResizability(.contentSize)

        // Leveling analytics: a dedicated, roomy window (not a dock tile) — the
        // four leveldb faces (live HUD / reports / analytics / journey) carry too
        // much to share the cramped dock. Read-only over the plugin's DB.
        Window("Levels", id: ProtelesApp.levelsWindowID) {
            LevelDBPanelView(model: levels)
                .frame(minWidth: 560, idealWidth: 820, minHeight: 420, idealHeight: 680)
                .navigationTitle("Levels")
        }
        .defaultSize(width: 820, height: 680)
        .windowResizability(.contentSize)

        Window("Lua Console", id: ProtelesApp.luaConsoleWindowID) {
            LuaConsoleView(model: luaConsole)
                .navigationTitle("Lua Console")
        }
        .defaultSize(width: 640, height: 400)

        Window("Plugins", id: ProtelesApp.pluginsWindowID) {
            PluginsView(model: plugins)
                .task(id: worlds.activeProfileID) {
                    guard let id = worlds.activeProfileID else { return }
                    plugins.prepare(profileID: id)
                    // A core-feature toggle (D-107) applies by reloading the
                    // world's scripts — the attach/arm gating lives there.
                    let scripts = scripts
                    plugins.resyncWorld = { await scripts.load(forProfile: id) }
                    await plugins.refreshNative()
                    await plugins.refresh()
                }
        }
        .windowResizability(.contentSize)
    }

    static let worldsWindowID = "worlds"
    static let scriptsWindowID = "scripts"
    static let pluginsWindowID = "plugins"
    static let helpWindowID = "help"
    static let levelsWindowID = "levels"
    static let luaConsoleWindowID = "luaConsole"

    /// `~/Library/Application Support/com.proteles.ProtelesApp/logs` — where
    /// user session logs are written (used by the log-file builder + the
    /// "Open Log Folder" menu item).
    nonisolated static func logsDirectory() -> URL? {
        // `~/Documents/Proteles/Logs/` (#43).
        try? ProtelesPaths.logsDirectory()
    }

    /// The current world name, set on connect so the (Sendable, off-main) log
    /// URL closure can place per-world logs without reaching into the UI models.
    nonisolated static let logContext = LogContext()

    /// Build the session-log URL: a per-world subfolder when enabled, pruning
    /// old logs to the retention limit first. Called by the session on connect.
    ///
    /// Register the built-in native plugins + the dialog/clipboard providers
    /// (split from `init` for its body-length budget).
    private static func registerNativePlugins(on scriptEngine: ScriptEngine) {
        Task {
            await scriptEngine.registerNativePlugin(AardGMCPHandler())
            await scriptEngine.registerNativePlugin(VitalShortcuts())
            await scriptEngine.registerNativePlugin(NoteMode())
            await scriptEngine.registerNativePlugin(TextSubstitution())
            await scriptEngine.registerNativePlugin(ChatEcho())
            await scriptEngine.registerNativePlugin(Soundpack())
            await scriptEngine.registerNativePlugin(AsciiMap())
            await scriptEngine.registerNativePlugin(ContinentBigmap())
            await scriptEngine.registerNativePlugin(TickTimer())
            await scriptEngine.registerNativePlugin(URLLinkify())
            await scriptEngine.registerNativePlugin(InventorySerialsPlugin())
            // Native `utils.*` dialogs (msgbox/inputbox/editbox/choose/file
            // pickers) for shim plugins that pop a dialog.
            await scriptEngine.setDialogProvider(makeScriptDialogProvider())
            // Native NSPasteboard for plugin GetClipboard/SetClipboard.
            await scriptEngine.setClipboardProvider(makeClipboardProvider())
        }
    }

    /// Save plugin state on quit (OnPluginSaveState + variable persist) —
    /// disconnect already saves; quitting while connected must too (`ldb on`
    /// was lost this way). Wired via ``AppDelegate/onTerminate``.
    private static func wireTerminationSave(session: SessionController) {
        Task { @MainActor in
            AppDelegate.onTerminate = { await session.savePluginState() }
        }
    }

    /// **`nonisolated`** (and the helpers it calls): the session invokes this from
    /// its own actor — *off* the main actor — via the `logFileURL` closure. SwiftUI's
    /// `App` protocol is `@MainActor`, which otherwise infers `@MainActor` onto every
    /// `ProtelesApp` member, so the off-main call trapped at runtime
    /// (`dispatch_assert_queue(main)`) the moment session logging was enabled. The
    /// work here is pure filesystem + `UserDefaults`, safe to run off-main.
    nonisolated static func makeLogURL(format: SessionLogFormat) -> URL? {
        guard let base = logsDirectory() else { return nil }
        let defaults = UserDefaults.standard
        let directory = perWorldSubfolder(of: base) ?? base
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneLogs(in: directory, keeping: defaults.object(forKey: "logRetention") as? Int ?? 30)
        let stamp = logTimestampFormatter.string(from: Date())
        let ext = format == .html ? "html" : "txt"
        return directory.appendingPathComponent("session-\(stamp).\(ext)")
    }

    /// The per-world log subfolder of `base`, or nil when per-world logging is
    /// off or no world name is set.
    private nonisolated static func perWorldSubfolder(of base: URL) -> URL? {
        guard UserDefaults.standard.bool(forKey: "perWorldLogs"),
              let world = logContext.worldName, !world.isEmpty else { return nil }
        return base.appendingPathComponent(logFolderName(world), isDirectory: true)
    }

    /// Delete the oldest `.txt`/`.html` logs in `directory` beyond `keeping`.
    nonisolated static func pruneLogs(in directory: URL, keeping: Int) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        let logs = files.filter { ["txt", "html"].contains($0.pathExtension.lowercased()) }
        for url in LogRetention.filesToPrune(logs, keeping: keeping) {
            try? manager.removeItem(at: url)
        }
    }

    /// A filesystem-safe folder name for a world (drops path separators/colons).
    nonisolated static func logFolderName(_ world: String) -> String {
        world.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
    }

    /// `nonisolated`: read from the off-main `makeLogURL` (touched serially on
    /// the session actor).
    nonisolated static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

/// Strips the empty "Format" menu AppKit leaves behind even after
/// `CommandGroup(replacing: .textFormatting) {}` — the editable command field
/// still contributes a Font/Text container. SwiftUI installs (and re-installs)
/// the menu bar at times we can't pin down, so a one-shot removal misses; we
/// instead observe `NSMenu` item additions and drop Format whenever it (re)
/// appears. A MUD client has no rich-text formatting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Runs before termination completes — set by `ProtelesApp.init` to save
    /// plugin state (`OnPluginSaveState` + variable persist), so quitting
    /// while connected doesn't lose state changed since connect (`ldb on`
    /// was lost this way; disconnect already saved, quit didn't).
    @MainActor static var onTerminate: (() async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let hook = Self.onTerminate else { return .terminateNow }
        Self.onTerminate = nil // run once; re-entry terminates immediately
        Task { @MainActor in
            await hook()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuItemAdded),
            name: NSMenu.didAddItemNotification,
            object: nil
        )
        // SwiftUI builds the menu on a detached NSMenu and swaps it into
        // NSApp.mainMenu after launch, so the observer can miss it. Sweep the
        // launch window with a few delayed passes too.
        for delay in [0.0, 0.2, 0.5, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.removeFormatMenu()
            }
        }
    }

    func applicationDidBecomeActive(_: Notification) {
        removeFormatMenu()
    }

    @objc private func menuItemAdded() {
        removeFormatMenu()
    }

    private func removeFormatMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let index = mainMenu.items.firstIndex(where: {
                  $0.title == "Format" || $0.submenu?.title == "Format"
              })
        else { return }
        mainMenu.removeItem(at: index)
    }
}
