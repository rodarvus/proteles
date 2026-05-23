import Foundation

/// Native port of Aardwolf's `aard_ASCII_map`: capture the server's ASCII
/// map (bracketed by `<MAPSTART>`/`<MAPEND>` once the map telnet-option is
/// on), hide that block from the main scrollback, and publish its styled
/// lines to the Map window.
///
/// On connect it enables Aardwolf telnet-option `MAP` (4) and requests a
/// map; on each `room.info` it re-requests, so the panel tracks your
/// location. The captured lines keep their colour runs (terrain shading).
public struct AsciiMap: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.asciimap",
        name: "ASCII Map",
        author: "Proteles (after Fiendish)",
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

    private var capturing = false
    private var buffer: [Line] = []

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

    public func onGMCP(package: String, json _: String) -> [ScriptEffect] {
        // Refresh the map when the room changes (response is captured/gagged).
        package.lowercased() == "room.info" ? [.send("map")] : []
    }
}
