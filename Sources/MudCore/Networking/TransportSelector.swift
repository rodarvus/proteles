import Foundation

/// Chooses which ``MudConnection`` a session opens, per the active world's
/// ``ConnectionTransport``. The app keeps it in sync with the active profile;
/// ``SessionController``'s `makeConnection` factory reads it at connect time, so
/// switching a world between Direct and WebSocket needs no change above the
/// transport. Lock-guarded + `Sendable` so the `@Sendable` factory can read it
/// from any isolation domain.
public final class TransportSelector: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: ConnectionTransport = .direct
    private let webSocketGatewayURL: URL

    public init(webSocketGatewayURL: URL = URL(string: "wss://play.aardwolf.com:6200/")!) {
        self.webSocketGatewayURL = webSocketGatewayURL
    }

    /// Point at the transport the next ``makeConnection()`` should build.
    public func set(_ transport: ConnectionTransport) {
        lock.withLock { self.transport = transport }
    }

    /// Build a fresh connection of the currently-selected transport.
    public func makeConnection() -> any MudConnection {
        switch lock.withLock({ transport }) {
        case .direct: NetworkConnection()
        case .webSocket: WebSocketConnection(gatewayURL: webSocketGatewayURL)
        }
    }
}
