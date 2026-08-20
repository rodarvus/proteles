import Foundation

/// The package's eight built-in non-channel capture classes. These are plain
/// output lines, not `comm.channel`; keeping them typed prevents them from
/// leaking into channel completion, notification, and speech settings.
public enum NonChannelKind: String, CaseIterable, Codable, Sendable, Hashable {
    case info
    case raidInfo = "raidinfo"
    case clanInfo = "claninfo"
    case clanDonations = "clan_donations"
    case globalQuest = "global_quest"
    case warfare
    case remortAuction = "remort_auction"
    case remoteSocials = "remote_socials"

    public var displayName: String {
        switch self {
        case .info: "INFO"
        case .raidInfo: "RAIDINFO"
        case .clanInfo: "CLANINFO"
        case .clanDonations: "Clan donations"
        case .globalQuest: "Global Quest"
        case .warfare: "Warfare"
        case .remortAuction: "Remort Auction"
        case .remoteSocials: "Remote socials"
        }
    }
}

/// A Channels-panel source: a real GMCP channel, a package-defined output
/// class, or a named capture supplied by another plugin.
public enum CommunicationSource: Codable, Sendable, Hashable, Equatable {
    case channel(String)
    case nonChannel(NonChannelKind)
    case plugin(String)

    public var name: String {
        switch self {
        case .channel(let name), .plugin(let name): name
        case .nonChannel(let kind): kind.rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .channel(let name): name
        case .nonChannel(let kind): kind.displayName
        case .plugin(let name): name.isEmpty ? "Capture" : name
        }
    }

    public var persistenceKind: String {
        switch self {
        case .channel: "channel"
        case .nonChannel: "nonchannel"
        case .plugin: "plugin"
        }
    }

    public init(persistenceKind: String, name: String) {
        switch persistenceKind {
        case "nonchannel": self = .nonChannel(NonChannelKind(rawValue: name) ?? .info)
        case "plugin": self = .plugin(name)
        default: self = .channel(name)
        }
    }

    fileprivate var policyKey: String {
        "\(persistenceKind):\(name.lowercased())"
    }
}

public struct CommunicationPolicySnapshot: Codable, Sendable, Equatable {
    public var echoChannels = true
    public var disabledCapture: Set<String> = []
    public var disabledEcho: Set<String> = []
    public var knownChannels: Set<String> = []

    public init() {}

    public func captures(_ source: CommunicationSource) -> Bool {
        !disabledCapture.contains(source.policyKey)
    }

    public func echoes(_ source: CommunicationSource) -> Bool {
        switch source {
        case .channel where !echoChannels: false
        default: !disabledEcho.contains(source.policyKey)
        }
    }
}

/// Lock-protected shared policy used by native capture, Chat Echo, and the UI.
/// Plugin-state persistence remains owned by Chat Echo; this object only makes
/// one live policy visible to those otherwise value-typed components.
public final class CommunicationPolicyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CommunicationPolicySnapshot()
    private var subscribers: [UUID: AsyncStream<CommunicationPolicySnapshot>.Continuation] = [:]

    public init() {}

    public func snapshot() -> CommunicationPolicySnapshot {
        lock.withLock { value }
    }

    public func replace(with snapshot: CommunicationPolicySnapshot) {
        update { $0 = snapshot }
    }

    public func learn(channel: String) {
        guard !channel.isEmpty else { return }
        update { $0.knownChannels.insert(channel.lowercased()) }
    }

    public func setEchoChannels(_ enabled: Bool) {
        update { $0.echoChannels = enabled }
    }

    public func setCapture(_ enabled: Bool, source: CommunicationSource) {
        updateSet(enabled, source: source, keyPath: \.disabledCapture)
    }

    public func setEcho(_ enabled: Bool, source: CommunicationSource) {
        updateSet(enabled, source: source, keyPath: \.disabledEcho)
    }

    public func subscribe() -> AsyncStream<CommunicationPolicySnapshot> {
        let id = UUID()
        let pair = AsyncStream<CommunicationPolicySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            subscribers[id] = pair.continuation
            pair.continuation.yield(value)
        }
        pair.continuation.onTermination = { [weak self] _ in self?.removeSubscriber(id) }
        return pair.stream
    }

    private func updateSet(
        _ enabled: Bool,
        source: CommunicationSource,
        keyPath: WritableKeyPath<CommunicationPolicySnapshot, Set<String>>
    ) {
        update {
            if enabled {
                $0[keyPath: keyPath].remove(source.policyKey)
            } else {
                $0[keyPath: keyPath].insert(source.policyKey)
            }
        }
    }

    private func update(_ body: (inout CommunicationPolicySnapshot) -> Void) {
        let result = lock.withLock { () -> (
            CommunicationPolicySnapshot,
            [AsyncStream<CommunicationPolicySnapshot>.Continuation]
        )? in
            let previous = value
            body(&value)
            guard value != previous else { return nil }
            return (value, Array(subscribers.values))
        }
        guard let (snapshot, continuations) = result else { return }
        for continuation in continuations {
            continuation.yield(snapshot)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        lock.withLock { subscribers[id] = nil }
    }
}
