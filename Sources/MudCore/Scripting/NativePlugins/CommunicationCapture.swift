import Foundation

/// Native counterpart of the package Communication Log. Registration order is
/// significant: Text Substitution runs first, this capture runs next, and Chat
/// Echo makes the main-output decision last.
public struct CommunicationCapture: NativePlugin {
    public static let pluginID = "com.proteles.communicationcapture"

    public let metadata = NativePluginMetadata(
        id: Self.pluginID,
        name: "Communication Capture",
        author: "Proteles (after Fiendish)",
        version: "1.0",
        summary: "Capture channels and Aardwolf information lines in the Channels panel."
    )

    private let policy: CommunicationPolicyStore

    public init(policy: CommunicationPolicyStore) {
        self.policy = policy
    }

    public mutating func onGMCP(
        package: String, json _: String, context: GMCPDispatchContext
    ) -> [ScriptEffect] {
        guard package.lowercased() == "comm.channel",
              let comm = context.communication,
              let line = context.communicationLine,
              !context.speakerMuted
        else { return [] }
        policy.learn(channel: comm.chan)
        let source = CommunicationSource.channel(comm.chan)
        let snapshot = policy.snapshot()
        guard snapshot.captures(source) else { return [] }
        let hidesDonation = context.isClanDonation
            && !snapshot.captures(.nonChannel(.clanDonations))
        if hidesDonation {
            return []
        }
        return [.communicationCapture(
            source: source,
            player: comm.player,
            line: line,
            showsTimestamp: true,
            shouldPersist: true
        )]
    }

    public func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        guard let kind = Self.classify(line) else { return .init() }
        let source = CommunicationSource.nonChannel(kind)
        let snapshot = policy.snapshot()
        let effects: [ScriptEffect] = snapshot.captures(source) ? [
            .communicationCapture(
                source: source,
                player: "",
                line: line,
                showsTimestamp: true,
                shouldPersist: true
            )
        ] : []
        // aard_chat_echo can hide the seven non-channel classes it knows.
        // Remote socials are only a Communication Log trigger and stay visible.
        let gag = kind != .remoteSocials && !snapshot.echoes(source)
        return .init(gag: gag, effects: effects)
    }

    /// Trigger shapes from `aard_channels_fiendish.xml`, with recording-backed
    /// exclusions for Aardwolf system output that shares the broad social form.
    public static func classify(_ line: Line) -> NonChannelKind? {
        let text = line.text
        if text.hasPrefix("Remort Auction:"), text.count > "Remort Auction:".count {
            return .remortAuction
        }
        if text.hasPrefix("Global Quest:"), text.count > "Global Quest:".count {
            return .globalQuest
        }
        if text.hasPrefix("INFO:"), text.count > "INFO:".count { return .info }
        if text.hasPrefix("RAIDINFO:"), text.count > "RAIDINFO:".count { return .raidInfo }
        if text.hasPrefix("CLANINFO:"), text.count > "CLANINFO:".count { return .clanInfo }
        let isWarfare = text.hasPrefix("WARFARE:") || text.hasPrefix("GENOCIDE:")
        let hasWarfareBody = text.split(separator: ":", maxSplits: 1).last?.isEmpty == false
        if isWarfare, hasWarfareBody {
            return .warfare
        }
        return isRemoteSocial(line) ? .remoteSocials : nil
    }

    private static func isRemoteSocial(_ line: Line) -> Bool {
        let text = line.text
        // NOTE/Task/Goal system messages observed in live recordings start
        // with two asterisks; genuine remote socials start with exactly one.
        guard !text.hasPrefix("**") else { return false }
        guard text.range(
            of: #"^\*\S(?!.*[\]\*] *$).+$"#,
            options: .regularExpression
        ) != nil else { return false }
        let exclusions = [
            #"^\*Crash\*, the .* smashes open\.$"#,
            #"^\*CRACK\* of a whip\. Giant slabs of unidentified rocks are being hewn from the ?$"#,
            #"^\*Purchase using 'buy <keywords without spaces>'$"#
        ]
        guard !exclusions.contains(where: {
            text.range(of: $0, options: .regularExpression) != nil
        }) else { return false }

        guard let first = line.runs.first(where: { $0.utf16Range.contains(0) }) else {
            return true // uncoloured/default-white line
        }
        return switch first.style.foreground {
        case nil, .named(.white), .named(.cyan), .brightNamed(.magenta): true
        default: false
        }
    }
}
