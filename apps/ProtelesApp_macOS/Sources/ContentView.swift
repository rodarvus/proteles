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
    @Bindable var layout: LayoutModel
    let chat: ChatModel
    let map: MapPanelModel
    let snd: SnDPanelModel
    @Environment(\.openWindow) private var openWindow
    @State private var connectionState: StatusBarView.ConnectionState = .disconnected
    @State private var gmcp = GMCPState()

    /// UserDefaults flag marking that the app has completed first-run
    /// setup (so we only auto-open the Worlds window once, ever).
    private static let hasLaunchedKey = "com.proteles.hasLaunchedBefore"

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                MudOutputView(store: session.scrollbackStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                CommandInputView { command in
                    Task {
                        try? await session.send(command)
                    }
                }
                StatusBarView(state: connectionState, gmcp: gmcp)
            }
            // Keep the vertical MUD output comfortably wide (~100+ cols)
            // regardless of the dock.
            .frame(minWidth: 640, maxWidth: .infinity)

            if layout.dockVisible {
                Divider()
                dock
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 560)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    layout.toggleDock()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle the panel dock")
            }
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
        .task {
            // Feed Search-and-Destroy's published window model to the panel.
            for await json in session.publishedModels {
                snd.update(json: json)
            }
        }
        .onAppear { wireSearchAndDestroy() }
        .task { await launch() }
    }

    /// The right-hand dock: a panel picker over the selected live panel.
    /// Single column so the output keeps its width; collapsible/resizable.
    private var dock: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $layout.selectedPanel) {
                ForEach(LayoutModel.Panel.allCases) { panel in
                    Label(panel.title, systemImage: panel.systemImage).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(6)
            Divider()
            switch layout.selectedPanel {
            case .info: InfoPanel(state: gmcp)
            case .map: MapPanelView(model: map)
            case .chat: ChatView(model: chat)
            case .hunt: SearchAndDestroyPanelView(model: snd)
            }
        }
    }

    /// Wire the S&D panel's actions to the live session: toolbar/row commands
    /// run through S&D's aliases, and the gear's "Import SnDdb.db…" opens a
    /// file picker and merges the chosen database into this world's store.
    private func wireSearchAndDestroy() {
        snd.onCommand = { command in
            Task { try? await session.send(command) }
        }
        snd.onImport = { importSearchAndDestroyDatabase() }
    }

    /// Pick an existing `SnDdb.db` and incrementally merge it into the active
    /// profile's S&D database (adds areas/mobs/history we don't already have).
    private func importSearchAndDestroyDatabase() {
        guard let profileID = worlds.activeProfileID else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a Search & Destroy database (SnDdb.db) to import."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task.detached {
            guard let url = try? SearchAndDestroyStore.defaultStoreURL(forProfile: profileID),
                  let store = try? SearchAndDestroyStore(url: url)
            else { return }
            _ = try? store.importIncremental(from: source)
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
