import MudCore
import MudOutputView_macOS
import MudUI
import SwiftUI

struct ContentView: View {
    let session: SessionController
    let worlds: WorldsModel
    @Environment(\.openWindow) private var openWindow
    @State private var connectionState: StatusBarView.ConnectionState = .disconnected

    /// UserDefaults flag marking that the app has completed first-run
    /// setup (so we only auto-open the Worlds window once, ever).
    private static let hasLaunchedKey = "com.proteles.hasLaunchedBefore"

    var body: some View {
        VStack(spacing: 0) {
            MudOutputView(store: session.scrollbackStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            CommandInputView { command in
                Task {
                    try? await session.send(command)
                }
            }
            StatusBarView(state: connectionState)
        }
        .task {
            for await networkState in session.connectionStates {
                connectionState = Self.map(networkState)
            }
        }
        .task { await launch() }
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
