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
    public let metadata = NativePluginMetadata(
        id: "com.proteles.chatecho",
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
        var echoEnabled = true
        var mutes: [Mute] = []
    }

    private struct Recent {
        let text: String
        let player: String
    }

    private var state = State()
    /// Recent comm.channel lines (stripped text → speaker), runtime only.
    private var recent: [Recent] = []
    private static let recentLimit = 40

    public init() {}

    // MARK: - Persistence

    public var persistentState: Data? {
        try? JSONEncoder().encode(state)
    }

    public mutating func restore(from data: Data) {
        if let restored = try? JSONDecoder().decode(State.self, from: data) {
            state = restored
        }
    }

    // MARK: - GMCP + lines

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        guard package.lowercased() == "comm.channel" else { return [] }
        guard let comm = try? JSONDecoder().decode(CommChannel.self, from: Data(json.utf8)) else {
            return []
        }
        let text = AardwolfColor.stripped(comm.msg).trimmingCharacters(in: .whitespaces)
        recent.append(Recent(text: text, player: comm.player))
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        // Faithful to aard_chat_echo: render the channel from GMCP (colored) into
        // the main window; `onLine` gags the raw inline duplicate. This is the
        // ONLY way held lines appear — a caught tell (`catchtells`) arrives via
        // comm.channel with its inline copy withheld by the server, so without
        // this echo it would be invisible. Suppressed when echo is off or the
        // speaker is muted (the inline copy is still gagged, so it's hidden).
        guard state.echoEnabled, !isMuted(comm.player, now: Date()) else { return [] }
        return [.echoAard(comm.msg)]
    }

    public func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        disposition(for: line, now: Date())
    }

    /// Gag the raw inline copy of any channel we hold GMCP for: the colored echo
    /// (or its deliberate suppression when echo is off / the speaker is muted)
    /// was decided in ``onGMCP(package:json:)``. This is pure de-duplication —
    /// faithful to aard_chat_echo, which renders channels from GMCP and hides the
    /// server's inline line. (`now` retained for the protocol/test signature.)
    func disposition(for line: Line, now _: Date) -> ScriptEngine.LineDisposition {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, recent.contains(where: { $0.text == text }) else { return .init() }
        return .init(gag: true)
    }

    func isMuted(_ player: String, now: Date) -> Bool {
        guard let mute = state.mutes.first(where: { $0.player == player.lowercased() }) else {
            return false
        }
        if let expiry = mute.expiry, expiry <= now { return false }
        return true
    }

    // MARK: - Commands

    public mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard parts.first?.lowercased() == "chats", parts.count >= 2 else { return nil }
        switch parts[1].lowercased() {
        case "echo": return handleEcho(parts)
        case "mute": return handleMute(parts, now: Date())
        case "unmute": return handleUnmute(parts)
        default: return nil
        }
    }

    private mutating func handleEcho(_ parts: [String]) -> [ScriptEffect] {
        switch parts.count >= 3 ? parts[2].lowercased() : "" {
        case "on":
            state.echoEnabled = true
            return [persist, Self.note("Channel echo on — channels show in the main window.")]
        case "off":
            state.echoEnabled = false
            return [persist, Self.note("Channel echo off — channels hidden from main (kept in Chat window).")]
        default:
            return [Self.note("Channel echo is \(state.echoEnabled ? "on" : "off").")]
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
