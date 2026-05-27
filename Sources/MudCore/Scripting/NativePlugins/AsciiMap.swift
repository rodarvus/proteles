import Foundation

/// Captures the server's ASCII map (bracketed by `<MAPSTART>`/`<MAPEND>` once
/// Aardwolf's map telnet-option is on), hides that block from the main
/// scrollback, and publishes its styled lines to the Map window. Independent
/// Swift implementation of this Aardwolf behaviour; inspired by Fiendish's
/// `aard_ASCII_map`.
///
/// On connect it enables Aardwolf telnet-option `MAP` (4) and requests a
/// map; on each `room.info` it re-requests, so the panel tracks your
/// location. The captured lines keep their colour runs (terrain shading).
public struct AsciiMap: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.asciimap",
        name: "ASCII Map",
        author: "Proteles",
        version: "1.0",
        summary: "Captures the server's ASCII map into the Map window and hides it from the main output."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Shows Aardwolf's ASCII area map in the Map window (⌘⇧B) and keeps it "
                + "out of the main output. Updates as you move. Runs automatically — no commands."
        )
    }

    /// Aardwolf telnet option that brackets the `map` output.
    private static let telnetOptionMap = 4
    /// `char.status.state` values in which it's safe to request a map —
    /// mirroring aard_ASCII_map's `can_request_map`: 3 (standing/playing)
    /// and 11 (AFK/idle, still in-world). Never during login (1), MOTD,
    /// note-writing (5), or combat (8), where a `map` command would be
    /// consumed as input or is unwanted.
    private static let mapRequestStates: Set<Int> = [3, 11]

    /// Aardwolf `maptype`: 0 = standard ASCII; 1–6 = solid-line maps that send
    /// **UTF-8 box-drawing** walls (`│ ─ ┌ …`) the server renders for us — far
    /// nicer than `|`/`-`. 5 = single-line "extended walls"; 6 = double-line.
    /// MUSHclient had to down-convert these to ASCII; we're natively UTF-8, so
    /// we render them verbatim. Sent `session`-only, so it doesn't alter the
    /// character's saved setting.
    private static let preferredMapType = 5

    private var capturing = false
    private var buffer: [Line] = []
    /// Whether we're currently in a state that permits a map request.
    private var playing = false
    /// Sent `maptype` once per session (on the first playing state).
    private var requestedMapType = false

    private struct StatusState: Decodable { let state: Int? }

    public init() {}

    public func connect() -> [ScriptEffect] {
        // Enable the map stream (telnet sub-negotiation — out-of-band, safe
        // during the login prompts). The first `map` request is deferred to
        // the first room.info so we never inject a game command before
        // login completes (which would be eaten as the name/password and
        // break auto-login).
        [.aardwolfTelnet(option: Self.telnetOptionMap, on: true)]
    }

    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        let marker = line.text.trimmingCharacters(in: .whitespaces)
        if marker == "<MAPSTART>" {
            capturing = true
            buffer = []
            return .init(gag: true)
        }
        guard capturing else { return .init() }
        if marker == "<MAPEND>" {
            capturing = false
            let captured = buffer
            buffer = []
            return .init(gag: true, effects: [.updateMap(captured)])
        }
        buffer.append(line)
        return .init(gag: true)
    }

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        switch package.lowercased() {
        case "char.status":
            // Track the play state; on the first playing state (just after
            // login) pick the solid-line map type, then request a map.
            let state = (try? JSONDecoder().decode(StatusState.self, from: Data(json.utf8)))?.state
            let nowPlaying = state.map(Self.mapRequestStates.contains) ?? false
            defer { playing = nowPlaying }
            guard nowPlaying, !playing else { return [] }
            var effects: [ScriptEffect] = []
            if !requestedMapType {
                requestedMapType = true
                effects.append(.send("maptype \(Self.preferredMapType) session"))
            }
            effects.append(.send("map"))
            return effects
        case "room.info":
            // Refresh on movement — but only while in a playing state, so we
            // never send `map` during login / note-writing / combat (it would
            // corrupt the note or break auto-login).
            return playing ? [.send("map")] : []
        default:
            return []
        }
    }
}
