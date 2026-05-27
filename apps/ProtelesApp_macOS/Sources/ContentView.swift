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
    @Environment(\.openWindow) private var openWindow
    @State private var connectionState: StatusBarView.ConnectionState = .disconnected
    @State private var gmcp = GMCPState()
    /// "Omit Blank Lines" display preference (View menu); pushed to the session
    /// on launch and whenever it changes. Same UserDefaults key as the toggle.
    @AppStorage("omitBlankLines") private var omitBlankLines = false

    /// UserDefaults flag marking that the app has completed first-run
    /// setup (so we only auto-open the Worlds window once, ever).
    private static let hasLaunchedKey = "com.proteles.hasLaunchedBefore"

    var body: some View {
        PanelLayoutView(store: layout, onDetach: detach) { kind in panelContent(kind) }
            .overlay(alignment: .topTrailing) {
                FloatingPanelLayer(store: layout) { kind in panelContent(kind) }
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
            .task {
                for await snapshot in await session.gmcpState.subscribe() {
                    gmcp = snapshot
                }
            }
            .task(id: omitBlankLines) {
                await session.setOmitBlankLines(omitBlankLines)
            }
            .task {
                // Feed Search-and-Destroy's published window model to the panel.
                for await json in session.publishedModels {
                    snd.update(json: json)
                }
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

    /// Tear `kind` out of the dock into its own window.
    private func detach(_ kind: PanelKind) {
        layout.detach(kind)
        openWindow(value: kind)
    }

    /// Map a panel kind to its live view (the layout engine supplies chrome).
    private func panelContent(_ kind: PanelKind) -> AnyView {
        switch kind {
        case .output: AnyView(gameColumn)
        case .map: AnyView(MapPanelView(model: map))
        case .asciiMap: AnyView(MapView(model: asciiMap))
        case .channels: AnyView(ChatView(model: chat))
        case .hunt: AnyView(SearchAndDestroyPanelView(model: snd))
        case .info: AnyView(InfoPanel(state: gmcp))
        }
    }

    /// The main game column: MUD output, command input, and the full-width
    /// graphical vitals bar (spanning the output, no duplicated text summary).
    private var gameColumn: some View {
        VStack(spacing: 0) {
            MudOutputView(store: session.scrollbackStore, onCommand: { command in
                Task { try? await session.send(command) }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            CommandInputView { command in
                Task { try? await session.send(command) }
            }
            GaugeBarView(state: connectionState, gmcp: gmcp)
        }
    }

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
    }

    /// Empty the active world's `SnDdb.db` (development/testing): confirm, then
    /// delete all areas/mobs/keywords/history so importing can be re-tested.
    private func resetSearchAndDestroyDatabase() {
        guard let profileID = worlds.activeProfileID else {
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
                let url = try SearchAndDestroyStore.defaultStoreURL(forProfile: profileID)
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
        guard let profileID = worlds.activeProfileID else {
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
                let url = try SearchAndDestroyStore.defaultStoreURL(forProfile: profileID)
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
