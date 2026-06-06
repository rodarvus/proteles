import AppKit
import MudCore
import MudOutputView_macOS
import MudUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let session: SessionController
    let worlds: WorldsModel
    let scripts: ScriptsModel
    let layout: LayoutStore
    let chat: ChatModel
    let map: MapPanelModel
    let asciiMap: MapModel
    let snd: SnDPanelModel
    /// In-game Help panel: receives captured help articles + drives navigation.
    let help: HelpPanelModel
    /// Native leveldb reporting panel (read-only over the plugin's DB).
    let levels: LevelDBPanelModel
    /// Import/reset hooks for the plugin-owned DBs (dinv, leveldb).
    let pluginDBs: PluginDatabasesModel
    /// Posts session notifications (tells/mentions) as macOS notifications.
    @State private var notifications = NotificationController()
    @Environment(\.openWindow) private var openWindow
    // Not `private` so the `ContentView+PluginDatabases` extension (separate
    // file) can gate import/reset on the live connection state.
    @State var connectionState: StatusBarView.ConnectionState = .disconnected
    @State private var gmcp = GMCPState()
    /// Recent output lines (plain text), the word source for Tab completion.
    /// A reference holder so appends don't trigger a view re-render.
    @State private var recentLines = RecentLineBuffer()
    /// Drives the "Save Layout…" name prompt.
    @State private var showingSavePreset = false
    @State private var newPresetName = ""
    /// "Omit Blank Lines" display preference (View menu); pushed to the session
    /// on launch and whenever it changes. Same UserDefaults key as the toggle.
    @AppStorage("omitBlankLines") private var omitBlankLines = false
    /// Hide leftover Aardwolf tag lines ({rname}/{coords}/…) from output.
    @AppStorage("gagTagLines") private var gagTagLines = false
    /// Rich Exits: clickable exit hyperlinks in the main output (View menu).
    @AppStorage("richExits") private var richExits = false
    /// Output font size (Appearance preference). Changing it recreates the
    /// output view, which re-renders the scrollback at the new size.
    @AppStorage("outputFontSize") private var outputFontSize = 13.0
    /// Output font family ("" = system monospaced). Recreates the output view.
    @AppStorage("outputFontName") private var outputFontName = ""
    /// Connection preferences (pushed to the session like omitBlankLines).
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("autoRecordSessions") private var autoRecordSessions = true
    @AppStorage("keepAlive") private var keepAlive = true
    /// User session logging (Logging preferences); pushed to the session, takes
    /// effect on the next connect.
    @AppStorage("sessionLogging") private var sessionLogging = false
    @AppStorage("sessionLogFormat") private var sessionLogFormat = "text"
    /// Notifications (Notifications preferences); pushed to the session.
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("notifyOnTells") private var notifyOnTells = true
    @AppStorage("notifyOnMention") private var notifyOnMention = true
    @AppStorage(NotificationRulesStorage.key) private var notificationRulesData = Data()
    /// Spell-check squiggles in the command input (General preference). Visual
    /// only; auto-correct/smart-quotes stay off regardless (they'd mangle
    /// commands). Default off — a command line squiggles a lot of game words.
    @AppStorage("commandSpellCheck") private var commandSpellCheck = false
    @AppStorage("inputGhostHint") private var inputGhostHint = true
    /// Deliver notifications even while Proteles is frontmost (opt-out of
    /// suppress-when-focused).
    @AppStorage("notifyWhenFocused") private var notifyWhenFocused = false
    /// Selected colour theme (Appearance preference). Drives the output palette
    /// and the app-wide light/dark chrome appearance.
    @AppStorage("themeID") private var themeID = Theme.default.id
    /// Keyboard "Navigation mode" (⌥⌘N, View menu). While on, bare-key macros
    /// fire on an empty input line; keypad/chord macros fire regardless. Shared
    /// with the menu toggle via the same UserDefaults key.
    @AppStorage("navigationMode") private var navigationMode = false

    // Status bar (bottom vitals bars) — per-bar visibility + number overlay mode.
    @AppStorage("statusBar.health") private var statusBarHealth = true
    @AppStorage("statusBar.mana") private var statusBarMana = true
    @AppStorage("statusBar.moves") private var statusBarMoves = true
    @AppStorage("statusBar.tnl") private var statusBarTNL = true
    @AppStorage("statusBar.enemy") private var statusBarEnemy = true
    @AppStorage("statusBar.align") private var statusBarAlign = true
    @AppStorage("statusBar.numberMode") private var statusBarNumberMode = StatusBarNumberMode.none.rawValue
    @AppStorage("statusBar.ticks") private var statusBarTicks = true
    // Per-bar colours (user-pickable). Defaults mirror StatusBarColors().
    @AppStorage("statusBar.color.health") private var statusColorHealth = "#00C000"
    @AppStorage("statusBar.color.mana") private var statusColorMana = "#2E6FFF"
    @AppStorage("statusBar.color.moves") private var statusColorMoves = "#FFFF00"
    @AppStorage("statusBar.color.tnl") private var statusColorTNL = "#CCCCCC"
    @AppStorage("statusBar.color.enemy") private var statusColorEnemy = "#FF3333"

    private var theme: Theme {
        Theme.with(id: themeID)
    }

    /// Assemble the persisted per-bar toggles + number mode into the value the
    /// gauge bar renders from.
    private var statusBarConfig: StatusBarConfig {
        StatusBarConfig(
            showHealth: statusBarHealth,
            showMana: statusBarMana,
            showMoves: statusBarMoves,
            showTNL: statusBarTNL,
            showEnemy: statusBarEnemy,
            showAlign: statusBarAlign,
            numberMode: StatusBarNumberMode(rawValue: statusBarNumberMode) ?? .none,
            showTicks: statusBarTicks,
            colors: StatusBarColors(
                health: statusColorHealth,
                mana: statusColorMana,
                moves: statusColorMoves,
                tnl: statusColorTNL,
                enemy: statusColorEnemy
            )
        )
    }

    /// UserDefaults flag marking that the app has completed first-run
    /// setup (so we only auto-open the Worlds window once, ever).
    private static let hasLaunchedKey = "com.proteles.hasLaunchedBefore"

    var body: some View {
        VStack(spacing: 0) {
            PanelLayoutView(store: layout, onDetach: detach) { kind in panelContent(kind) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Full-client-width vitals bars, below the whole dock (pushes the
            // panes up), so all six bars get the window's full horizontal extent.
            if !statusBarConfig.isEmpty {
                GaugeBarView(state: connectionState, gmcp: gmcp, config: statusBarConfig)
            }
        }
        .frame(minWidth: 820, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { panelsMenu }
        }
        .task {
            for await networkState in session.connectionStates {
                connectionState = Self.map(networkState)
            }
        }
        // Main-thread stall monitor (perf diagnostics) — logs UI-thread hitches
        // to the session transcript. Body lives in the extension (type budget).
        .task { await monitorMainThreadStalls() }
        .task {
            for await snapshot in await session.gmcpState.subscribe() {
                gmcp = snapshot
            }
        }
        // Feed recent output lines to the Tab-completion word source.
        .task {
            for await line in await session.scrollbackStore.subscribe() {
                recentLines.append(line.text)
            }
        }
        .task(id: omitBlankLines) {
            await session.setOmitBlankLines(omitBlankLines)
        }
        .task(id: gagTagLines) {
            await session.setGagTagLines(gagTagLines)
        }
        .task(id: richExits) {
            await session.setRichExitsEnabled(richExits)
        }
        // Help is captured to the dedicated Help window (always on, so
        // `help <topic>` can auto-open it); never printed inline.
        .task {
            await session.setHelpCaptureEnabled(true)
        }
        // Feed captured help articles to the Help window, auto-opening it,
        // and route its link clicks + search back to the session.
        .task {
            help.onCommand = { command in Task { try? await session.send(command) } }
            for await article in session.helpArticles {
                await help.apply(article)
                openWindow(id: ProtelesApp.helpWindowID)
            }
        }
        .task(id: autoReconnect) {
            await session.setReconnectEnabled(autoReconnect)
        }
        .task(id: autoRecordSessions) {
            await session.setAutoRecord(autoRecordSessions)
        }
        .task(id: keepAlive) {
            await session.setKeepAliveEnabled(keepAlive)
        }
        .task(id: sessionLogging) {
            await session.setLoggingEnabled(sessionLogging)
        }
        .task(id: sessionLogFormat) {
            await session.setLogFormat(sessionLogFormat == "html" ? .html : .text)
        }
        .task(id: notificationsEnabled) {
            await session.setNotificationsEnabled(notificationsEnabled)
            if notificationsEnabled { notifications.requestAuthorizationIfNeeded() }
        }
        .task(id: "\(notifyOnTells)|\(notifyOnMention)|\(notificationRulesData.hashValue)") {
            await session.setNotificationRules(tells: notifyOnTells, mention: notifyOnMention)
            await session.setCustomNotificationRules(.decoded(from: notificationRulesData))
        }
        .task(id: notifyWhenFocused) {
            notifications.notifyWhenFocused = notifyWhenFocused
        }
        .task {
            for await note in session.notifications {
                notifications.post(note)
            }
        }
        .task {
            // Apply script/plugin button-bar changes (#15 v3) to the live bar.
            for await command in session.buttonCommands {
                await scripts.applyButtonCommand(command)
            }
        }
        .task(id: themeID) {
            // Flip the whole app's chrome (panels, materials, gauges) to
            // match the theme's light/dark appearance.
            NSApp.appearance = NSAppearance(named: theme.appearance == .light ? .aqua : .darkAqua)
        }
        .task {
            // Feed Search-and-Destroy's published window model to the panel.
            for await json in session.publishedModels {
                snd.update(json: json)
            }
        }
        .alert("Save Layout Preset", isPresented: $showingSavePreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") { layout.savePreset(named: newPresetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save the current panel arrangement so you can re-apply it later.")
        }
        .onAppear {
            wireSearchAndDestroy()
            // Bind the mapper at the app root so it's live regardless of which
            // dock tab is shown (e.g. for a menu-triggered map import).
            map.start()
            // Re-open windows for panels that were detached last session.
            for kind in layout.detached {
                openWindow(value: kind)
            }
        }
        .task { await launch() }
    }

    // `detach(_:)` + `panelContent(_:)` live in the extension below (keeps the
    // view body within the type-length budget).

    /// The main game column: MUD output + command input. (The graphical vitals
    /// bar lives at the window level so it spans the full client width — see
    /// ``body``.)
    private var gameColumn: some View {
        VStack(spacing: 0) {
            MudOutputView(
                store: session.scrollbackStore,
                palette: theme.palette,
                fontSize: CGFloat(outputFontSize),
                fontName: outputFontName,
                onCommand: { command in Task { try? await session.send(command) } },
                onFrameFlush: { stats in logSlowFrame(stats) }
            )
            // Recreate (and re-render) when the theme or output font changes.
            .id("\(themeID)|\(outputFontName)|\(outputFontSize)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Floating miniwindows (e.g. the Text Map) anchor to the top-right of
            // the game output, layered over it — not over the side dock.
            .overlay(alignment: .topTrailing) {
                FloatingPanelLayer(store: layout) { kind in panelContent(kind) }
            }
            CommandInputView(
                onSubmit: { command in Task { try? await session.send(command) } },
                onMacroKey: { chord, inputIsEmpty in
                    let context = MacroContext(
                        inputIsEmpty: inputIsEmpty,
                        navigationModeOn: navigationMode
                    )
                    // Macros take precedence; a command-button hotkey (#40) is the
                    // fallback binding for the same chord.
                    if let action = scripts.matchMacro(chord, context: context) {
                        Task { await session.fire(action) }
                        return true
                    }
                    if let buttonID = scripts.matchButtonHotkey(chord, context: context) {
                        Task { await scripts.fireButton(buttonID) }
                        return true
                    }
                    return false
                },
                vocabulary: { makeCompletionVocabulary() },
                spellChecking: commandSpellCheck,
                ghostHint: inputGhostHint
            )
            .overlay(alignment: .trailing) {
                if navigationMode {
                    Text("NAV")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .padding(.trailing, 12)
                        .help("Navigation mode: bare keys send movement while the input line is empty.")
                }
            }
        }
    }

    /// Build the current Tab-completion vocabulary: live GMCP nouns (room name
    /// words + group member names) as context, recent output words, and a
    /// verb set (movement/common commands + channel names) for the first word.
    /// Called on Tab, so harvesting recent lines here is cheap.
    private func makeCompletionVocabulary() -> CompletionVocabulary {
        var context: [String] = []
        if let members = gmcp.group?.members { context += members.map(\.name) }
        if let roomName = gmcp.room?.name {
            context += InputCompletion.harvestWords(from: [roomName], minLength: 3)
        }
        return CompletionVocabulary(
            contextWords: context,
            recentWords: InputCompletion.harvestWords(from: recentLines.snapshot),
            verbs: Self.completionVerbs
        )
    }

    /// First-word completion verbs: common Aardwolf commands + the channel
    /// names (so `gos`→`gossip`). Aliases can join this later.
    private static let completionVerbs: [String] = {
        let commands = [
            "north", "south", "east", "west", "northeast", "northwest",
            "southeast", "southwest", "look", "examine", "consider", "kill",
            "cast", "get", "give", "drop", "put", "wear", "wield", "hold",
            "remove", "quaff", "recite", "eat", "drink", "open", "close",
            "unlock", "enter", "recall", "rest", "sleep", "wake", "stand",
            "flee", "scan", "where", "inventory", "equipment", "score",
            "practice", "train", "buy", "sell", "list", "rent", "campaign",
            "quest", "gquest", "run", "speedwalk"
        ]
        return commands + Array(CommandHistory.communicationCommands)
    }()

    /// Toolbar menu to show/hide each panel + reset the layout.
    private var panelsMenu: some View {
        Menu {
            ForEach(PanelKind.toggleable) { kind in
                Toggle(isOn: Binding(
                    get: { layout.isVisible(kind) },
                    set: { _ in layout.toggle(kind) }
                )) {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
            Divider()
            if !layout.presets.isEmpty {
                Menu("Apply Layout") {
                    ForEach(layout.presets) { preset in
                        Button(preset.name) { layout.applyPreset(preset) }
                    }
                }
                Menu("Delete Layout") {
                    ForEach(layout.presets) { preset in
                        Button(preset.name) { layout.deletePreset(named: preset.name) }
                    }
                }
            }
            Button("Save Layout…") { newPresetName = ""; showingSavePreset = true }
            Button("Reset Layout") { layout.resetToDefault() }
        } label: {
            Image(systemName: "rectangle.3.group")
        }
        .help("Show or hide panels")
    }

    /// Wire the S&D panel's actions to the live session: toolbar/row commands
    /// run through S&D's aliases, and the gear's "Import SnDdb.db…" opens a
    /// file picker and merges the chosen database into this world's store.
    private func wireSearchAndDestroy() {
        snd.onCommand = { command in
            Task { try? await session.send(command) }
        }
        snd.onImport = { importSearchAndDestroyDatabase() }
        snd.onScan = { Task { await session.scanSearchAndDestroy() } }
        snd.onReset = { resetSearchAndDestroyDatabase() }
        snd.onInstall = { installSearchAndDestroy() }
        snd.isInstalled = scripts.isSearchAndDestroyInstalled
        pluginDBs.onImportDinv = { importPluginDatabase(.dinv) }
        pluginDBs.onResetDinv = { resetPluginDatabase(.dinv) }
        pluginDBs.onImportLevelDB = { importPluginDatabase(.levelDB) }
        pluginDBs.onResetLevelDB = { resetPluginDatabase(.levelDB) }
    }

    /// Download + install the Search-and-Destroy plugin on request (S&D isn't
    /// bundled), then attach it live and update the panel's installed state.
    private func installSearchAndDestroy() {
        snd.installError = nil
        snd.isInstalling = true
        Task {
            do {
                try await scripts.installSearchAndDestroy()
                snd.isInstalled = scripts.isSearchAndDestroyInstalled
                await session.echoSystemNote(
                    "[S&D] Installed. Start a campaign or quest to see targets here."
                )
            } catch {
                snd.installError = error.localizedDescription
            }
            snd.isInstalling = false
        }
    }

    /// Empty the active world's `SnDdb.db` (development/testing): confirm, then
    /// delete all areas/mobs/keywords/history so importing can be re-tested.
    private func resetSearchAndDestroyDatabase() {
        guard worlds.activeProfileID != nil else {
            Task { await session.echoSystemNote("[S&D] Connect to a world first, then reset.") }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Empty the Search & Destroy database?"
        alert.informativeText = "This permanently deletes all areas, mobs, keyword exceptions, and "
            + "history for this world. For development and testing."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Database")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let url = try SearchAndDestroyStore.defaultStoreURL()
                try SearchAndDestroyStore(url: url).empty()
                await session.echoSystemNote("[S&D] Database reset to empty (testing).")
            } catch {
                await session.echoSystemNote("[S&D] Reset failed.")
            }
        }
    }

    /// Pick an existing `SnDdb.db` and incrementally merge it into the active
    /// profile's S&D database (adds areas/mobs/history we don't already have).
    private func importSearchAndDestroyDatabase() {
        guard worlds.activeProfileID != nil else {
            Task { await session.echoSystemNote("[S&D] Connect to a world first, then import.") }
            return
        }
        let panel = NSOpenPanel()
        // SQLite .db files don't conform to UTType.database (public.database),
        // which greys them out; match by extension like the mapper picker.
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Search & Destroy database (SnDdb.db) to import."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let accessing = source.startAccessingSecurityScopedResource()
        Task {
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            do {
                let url = try SearchAndDestroyStore.defaultStoreURL()
                let store = try SearchAndDestroyStore(url: url)
                let summary = try store.importIncremental(from: source)
                await session.echoSystemNote(
                    summary.isEmpty
                        ? "[S&D] Import: nothing new — already had everything in that file."
                        : "[S&D] Import: added \(summary.mobs) mobs, \(summary.areas) areas, "
                        + "\(summary.keywords) keywords, \(summary.history) history rows."
                )
            } catch {
                await session.echoSystemNote(
                    "[S&D] Import failed — that file may not be a Search & Destroy database."
                )
            }
        }
    }

    /// Load profiles, then either guide a first-time user to the Worlds
    /// window (so they can connect or enter credentials) or auto-connect
    /// the active profile on subsequent launches.
    private func launch() async {
        await worlds.load()

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.hasLaunchedKey) {
            defaults.set(true, forKey: Self.hasLaunchedKey)
            openWindow(id: ProtelesApp.worldsWindowID)
            return
        }

        if let active = worlds.activeProfile, active.autoconnect {
            ProtelesApp.logContext.worldName = active.name
            await scripts.load(forProfile: active.id)
            try? await session.connect(
                to: active.endpoint,
                autologin: worlds.autologinPlan(for: active)
            )
        }
    }

    private static func map(
        _ state: NetworkConnection.State
    ) -> StatusBarView.ConnectionState {
        switch state {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .closing: .reconnecting
        }
    }
}

extension ContentView {
    /// Tear `kind` out of the dock into its own window.
    func detach(_ kind: PanelKind) {
        layout.detach(kind)
        openWindow(value: kind)
    }

    /// Map a panel kind to its live view (the layout engine supplies chrome).
    /// A ~500ms MainActor heartbeat; a late wake means the UI thread was blocked
    /// that long, logged to the transcript so perf hitches are visible in a
    /// recording. Cheap (one wake/500ms; logs only on a real stall).
    func monitorMainThreadStalls() async {
        // A 50 ms heartbeat resolves the sub-second hitches that make movement
        // feel "jagged" (a 500 ms beat can't even see a 150 ms block). Log when
        // a wake overruns its budget by >80 ms — i.e. the main thread was busy
        // that long — so a recording timestamps each hitch. (Perf diagnosis.)
        let beat = Duration.milliseconds(50)
        let budget = beat / .milliseconds(1) / 1000 // seconds
        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: beat)
            let now = Date()
            let overrun = now.timeIntervalSince(last) - budget
            last = now
            if overrun > 0.08 {
                await session.recordNote("UI stall: main thread blocked ~\(Int(overrun * 1000))ms")
            }
        }
    }

    /// Perf probe: log only frames that overran a 60 fps paint budget *or*
    /// showed a high arrival→paint latency, so the transcript reveals jagged
    /// hitches without noise. The flush runs on the main actor, so a slow one
    /// directly stutters the scroll; a high arrival→paint latency with a *low*
    /// flush time means the stall is upstream (GMCP dispatch / queueing), not the
    /// paint. (Diagnosis — perf arc.)
    func logSlowFrame(_ stats: RenderFrameStats) {
        let flushMS = stats.flushDuration / .milliseconds(1)
        let latencyMS = stats.maxArrivalLatency * 1000
        guard flushMS > 12 || latencyMS > 120 else { return }
        let note = "render: \(stats.appendedLines) line(s) "
            + "flush \(Int(flushMS))ms arrival→paint \(Int(latencyMS))ms"
        Task { await session.recordNote(note) }
    }

    func panelContent(_ kind: PanelKind) -> AnyView {
        switch kind {
        case .output: AnyView(gameColumn)
        case .map: AnyView(MapPanelView(model: map))
        case .asciiMap: AnyView(MapView(model: asciiMap))
        case .channels: AnyView(ChatView(model: chat))
        case .hunt: AnyView(SearchAndDestroyPanelView(model: snd))
        case .info: AnyView(InfoPanel(state: gmcp))
        case .group: AnyView(GroupPanel(state: gmcp))
        case .help: AnyView(HelpPanelView(model: help))
        case .levels: AnyView(LevelDBPanelView(model: levels))
        case .commandBar: AnyView(CommandBarView(scripts: scripts))
        }
    }
}

/// A small bounded ring of recent output lines (plain text) — the word source
/// for Tab completion. A reference type so the scrollback subscription can
/// append without triggering a SwiftUI re-render of ``ContentView``.
@MainActor
final class RecentLineBuffer {
    private var lines: [String] = []
    private let capacity: Int

    init(capacity: Int = 250) {
        self.capacity = capacity
    }

    func append(_ text: String) {
        lines.append(text)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    /// Oldest-first, as ``InputCompletion/harvestWords`` expects.
    var snapshot: [String] {
        lines
    }
}
