import Foundation

/// Declutters the main window by hiding channel chatter (still captured in the
/// Chat window) and muting specific players (independent Swift implementation
/// of this Aardwolf behaviour; inspired by Fiendish's `aard_chat_echo`).
///
/// Channels arrive as structured `comm.channel` GMCP, and normally *also* as an
/// inline text line. Faithful to aard_chat_echo, this plugin renders the channel
/// **from GMCP** — ``onGMCP(package:json:)`` emits a colored ``ScriptEffect/echoAard(_:)``
/// — and ``onLine(_:)`` gags the raw inline duplicate. Rendering from GMCP is what
/// surfaces **held** lines: a caught tell (`catchtells`) arrives via comm.channel
/// with its inline copy withheld by the server, so the echo is the only way it
/// shows. Echo off / muted speakers are suppressed (no echo, inline still gagged).
/// State persists per world.
public struct ChatEcho: NativePlugin {
    /// Stable id other plugins (and the registry's GMCP pre-answer, #55)
    /// target with `CallPlugin`-style queries.
    public static let pluginID = "com.proteles.chatecho"

    public let metadata = NativePluginMetadata(
        id: pluginID,
        name: "Chat Echo",
        author: "Proteles",
        version: "1.0",
        summary: "Hide channel chatter from the main window (kept in the Chat window) and mute players."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Channels still appear in the Chat window; this controls whether they "
                + "also clutter the main output, and lets you mute individual players. "
                + "Settings persist per world.",
            commands: [
                .init(syntax: "chats echo on", summary: "Show channels in the main window"),
                .init(syntax: "chats echo off", summary: "Hide channels from the main window"),
                .init(syntax: "chats mute <who> [min]", summary: "Mute a player (optionally for N minutes)"),
                .init(syntax: "chats unmute <who>", summary: "Stop muting a player"),
                .init(syntax: "chats mute", summary: "List muted players"),
                .init(syntax: "chats mute clear", summary: "Clear the mute list")
            ]
        )
    }

    // MARK: - State

    private struct Mute: Codable, Equatable {
        var player: String
        var expiry: Date?
    }

    private struct State: Codable, Equatable {
        var policy = CommunicationPolicySnapshot()
        var mutes: [Mute] = []

        private enum CodingKeys: String, CodingKey {
            case policy, mutes, echoEnabled
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            policy = try values.decodeIfPresent(
                CommunicationPolicySnapshot.self, forKey: .policy
            ) ?? CommunicationPolicySnapshot()
            // v1 stored one global echo flag. Carry it into the richer policy.
            if let legacy = try values.decodeIfPresent(Bool.self, forKey: .echoEnabled) {
                policy.echoChannels = legacy
            }
            mutes = try values.decodeIfPresent([Mute].self, forKey: .mutes) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(policy, forKey: .policy)
            try values.encode(mutes, forKey: .mutes)
        }
    }

    private struct Recent {
        let text: String
        let player: String
        let channel: String
        let receivedAt: Date
    }

    private struct PendingFragment {
        var remaining: String
        let expiresAt: Date
    }

    private var state = State()
    private let policy: CommunicationPolicyStore
    /// Recent comm.channel lines (stripped text → speaker), runtime only.
    private var recent: [Recent] = []
    private var pendingFragment: PendingFragment?
    private var inNoteMode = false
    private var noteModeBuffer: [Line] = []
    private static let recentLimit = 40
    private static let matchWindow: TimeInterval = 2
    private static let minimumFragmentLength = 24

    public init(policy: CommunicationPolicyStore = CommunicationPolicyStore()) {
        self.policy = policy
    }

    // MARK: - Persistence

    public var persistentState: Data? {
        var persisted = state
        persisted.policy = policy.snapshot()
        return try? JSONEncoder().encode(persisted)
    }

    public mutating func restore(from data: Data) {
        if let restored = try? JSONDecoder().decode(State.self, from: data) {
            state = restored
            policy.replace(with: restored.policy)
        }
    }

    // MARK: - GMCP + lines

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        let comm = try? JSONDecoder().decode(CommChannel.self, from: Data(json.utf8))
        let context = GMCPDispatchContext(
            communication: comm,
            communicationLine: comm.map { AardwolfColor.styledLine(from: $0.msg) }
        )
        return onGMCP(package: package, json: json, context: context)
    }

    public mutating func onGMCP(
        package: String, json: String, context: GMCPDispatchContext
    ) -> [ScriptEffect] {
        if package.lowercased() == "char.status" {
            return updateNoteMode(json: json)
        }
        guard package.lowercased() == "comm.channel",
              let comm = context.communication,
              let line = context.communicationLine
        else { return [] }
        policy.learn(channel: comm.chan)
        let text = Self.normalized(line.text)
        recent.append(Recent(
            text: text,
            player: comm.player,
            channel: comm.chan.lowercased(),
            receivedAt: Date()
        ))
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        // Faithful to aard_chat_echo: render the channel from GMCP (colored) into
        // the main window; `onLine` gags the raw inline duplicate. This is the
        // ONLY way held lines appear — a caught tell (`catchtells`) arrives via
        // comm.channel with its inline copy withheld by the server, so without
        // this echo it would be invisible. Suppressed when echo is off or the
        // speaker is muted (the inline copy is still gagged, so it's hidden).
        let snapshot = policy.snapshot()
        let channelSource = CommunicationSource.channel(comm.chan)
        guard snapshot.echoes(channelSource), !isMuted(comm.player, now: Date()) else { return [] }
        let hidesDonation = context.isClanDonation
            && !snapshot.echoes(.nonChannel(.clanDonations))
        if hidesDonation {
            return []
        }
        if inNoteMode {
            noteModeBuffer.append(line)
            return []
        }
        return [.echoLine(line)]
    }

    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        disposition(for: line, now: Date())
    }

    /// Gag the raw inline copy of any channel we hold GMCP for: the colored echo
    /// (or its deliberate suppression when echo is off / the speaker is muted)
    /// was decided in ``onGMCP(package:json:)``. This is pure de-duplication —
    /// faithful to aard_chat_echo, which renders channels from GMCP and hides the
    /// server's inline line. Aardwolf wraps long mobsays into two to four raw
    /// lines after emitting one complete GMCP message, so those fragments are
    /// consumed in order from a short-lived pending match.
    mutating func disposition(for line: Line, now: Date) -> ScriptEngine.LineDisposition {
        let text = Self.normalized(line.text)
        guard !text.isEmpty else { return .init() }

        recent.removeAll { now.timeIntervalSince($0.receivedAt) > Self.matchWindow }
        if let pendingFragment, now > pendingFragment.expiresAt {
            self.pendingFragment = nil
        }

        if var pendingFragment {
            if pendingFragment.remaining == text {
                self.pendingFragment = nil
                return .init(gag: true)
            }
            let prefix = text + " "
            if pendingFragment.remaining.hasPrefix(prefix) {
                pendingFragment.remaining.removeFirst(prefix.count)
                self.pendingFragment = pendingFragment
                return .init(gag: true)
            }
            self.pendingFragment = nil
        }

        if let index = recent.lastIndex(where: { $0.text == text }) {
            recent.remove(at: index)
            return .init(gag: true)
        }

        guard text.count >= Self.minimumFragmentLength,
              let index = recent.lastIndex(where: {
                  $0.channel == "mobsay" && $0.text.hasPrefix(text + " ")
              })
        else { return .init() }
        let matched = recent.remove(at: index)
        pendingFragment = PendingFragment(
            remaining: String(matched.text.dropFirst(text.count + 1)),
            expiresAt: now.addingTimeInterval(Self.matchWindow)
        )
        return .init(gag: true)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func isMuted(_ player: String, now: Date) -> Bool {
        guard let mute = state.mutes.first(where: { $0.player == player.lowercased() }) else {
            return false
        }
        if let expiry = mute.expiry, expiry <= now { return false }
        return true
    }

    /// The reference chat plugin's `checkIfMuted(player)` — the entry point
    /// the soundpack consults before playing a channel cue (#55). Re-validates
    /// time-limited mutes at call time, so an expired mute answers false.
    public func call(_ function: String, _ arguments: [LuaValue]) -> [LuaValue] {
        guard function == "checkIfMuted", let player = arguments.first?.stringValue else {
            return []
        }
        return [.boolean(isMuted(player, now: Date()))]
    }

    // MARK: - Commands

    public mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard parts.first?.lowercased() == "chats", parts.count >= 2 else { return nil }
        switch parts[1].lowercased() {
        case "echo": return handleEcho(parts)
        case "capture": return handleCapture(parts)
        case "save": return [persist]
        case "mute": return handleMute(parts, now: Date())
        case "unmute": return handleUnmute(parts)
        default: return nil
        }
    }

    private mutating func handleEcho(_ parts: [String]) -> [ScriptEffect] {
        if parts.count >= 5, let source = Self.source(kind: parts[2], name: parts[3]) {
            guard let enabled = Self.onOff(parts[4]) else { return [Self.note("Use on or off.")] }
            policy.setEcho(enabled, source: source)
            return [persist]
        }
        switch parts.count >= 3 ? parts[2].lowercased() : "" {
        case "on":
            policy.setEchoChannels(true)
            return [persist, Self.note("Channel echo on — channels show in the main window.")]
        case "off":
            policy.setEchoChannels(false)
            return [persist, Self.note("Channel echo off — channels hidden from main (kept in Chat window).")]
        default:
            return [Self.note("Channel echo is \(policy.snapshot().echoChannels ? "on" : "off").")]
        }
    }

    private mutating func handleCapture(_ parts: [String]) -> [ScriptEffect] {
        guard parts.count >= 5,
              let source = Self.source(kind: parts[2], name: parts[3]),
              let enabled = Self.onOff(parts[4])
        else { return [Self.note("Usage: chats capture channel|nonchannel <name> on|off")] }
        policy.setCapture(enabled, source: source)
        return [persist]
    }

    private mutating func updateNoteMode(json: String) -> [ScriptEffect] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = (object["state"] as? NSNumber)?.intValue
        else { return [] }
        let wasInNoteMode = inNoteMode
        inNoteMode = state == 5
        guard wasInNoteMode, !inNoteMode, !noteModeBuffer.isEmpty else { return [] }
        let buffered = noteModeBuffer
        noteModeBuffer.removeAll(keepingCapacity: true)
        return [Self.note("Channel messages received while editing:")] + buffered.map(ScriptEffect.echoLine)
    }

    private static func source(kind: String, name: String) -> CommunicationSource? {
        switch kind.lowercased() {
        case "channel": .channel(name)
        case "nonchannel": NonChannelKind(rawValue: name).map(CommunicationSource.nonChannel)
        case "plugin": .plugin(name)
        default: nil
        }
    }

    private static func onOff(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on": true
        case "off": false
        default: nil
        }
    }

    private mutating func handleMute(_ parts: [String], now: Date) -> [ScriptEffect] {
        // "chats mute" → list; "chats mute clear" → clear; else add.
        guard parts.count >= 3 else { return listMutes(now: now) }
        if parts[2].lowercased() == "clear" {
            state.mutes.removeAll()
            return [persist, Self.note("Mute list cleared.")]
        }
        let player = parts[2].lowercased()
        let minutes = parts.count >= 4 ? Int(parts[3]) : nil
        let expiry = minutes.map { now.addingTimeInterval(Double($0) * 60) }
        state.mutes.removeAll { $0.player == player }
        state.mutes.append(Mute(player: player, expiry: expiry))
        let suffix = minutes.map { " for \($0) min" } ?? ""
        return [persist, Self.note("Muting \(parts[2])\(suffix).")]
    }

    private mutating func handleUnmute(_ parts: [String]) -> [ScriptEffect] {
        guard parts.count >= 3 else { return [Self.note("Usage: chats unmute <who>")] }
        let player = parts[2].lowercased()
        let removed = state.mutes.contains { $0.player == player }
        state.mutes.removeAll { $0.player == player }
        return removed
            ? [persist, Self.note("No longer muting \(parts[2]).")]
            : [Self.note("\(parts[2]) wasn't muted.")]
    }

    private func listMutes(now: Date) -> [ScriptEffect] {
        let active = state.mutes.filter { $0.expiry.map { $0 > now } ?? true }
        guard !active.isEmpty else { return [Self.note("No muted players.")] }
        var output = [Self.note("Muted players:")]
        for mute in active {
            let remaining = mute.expiry.map { expiry -> String in
                let minutes = Int((expiry.timeIntervalSince(now) / 60).rounded(.up))
                return " (\(minutes)m left)"
            } ?? " (permanent)"
            output.append(Self.note("  \(mute.player)\(remaining)"))
        }
        return output
    }

    private var persist: ScriptEffect {
        .persistPluginState(id: metadata.id)
    }

    private static func note(_ text: String) -> ScriptEffect {
        .colourNote([NoteSegment(text: text, foreground: "#C0C0C0")])
    }
}
