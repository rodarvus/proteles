import SwiftUI

/// Minimal status bar shown along the bottom of the main window in Phase 0.
///
/// This is a placeholder for the eventual rich status bar (HP/MP/MV gauges
/// from `Char.Vitals`, tick indicator, latency, channel mentions, ...).
/// For now it just reports connection state.
public struct StatusBarView: View {
    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    private let state: ConnectionState

    public init(state: ConnectionState = .disconnected) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(.callout))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .disconnected: .secondary
        case .connecting, .reconnecting: .yellow
        case .connected: .green
        }
    }

    private var label: String {
        switch state {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
        StatusBarView(state: .disconnected)
    }
    .frame(width: 600, height: 200)
}
