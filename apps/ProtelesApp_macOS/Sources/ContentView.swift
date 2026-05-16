import MudCore
import MudOutputView_macOS
import MudUI
import SwiftUI

struct ContentView: View {
    let session: SessionController
    @State private var connectionState: StatusBarView.ConnectionState = .disconnected

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
