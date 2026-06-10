import Foundation

/// Captures Aardwolf's continent "bigmap" (bracketed by `{bigmap}zone,name` /
/// `{/bigmap}` once telnet-option `BIGMAP` (2) is on) and publishes it to the
/// map panel, which renders it while the player is overland
/// (`coord.cont == 1`). Independent Swift implementation of this Aardwolf
/// behaviour; inspired by Fiendish's `Aardwolf_Bigmap_Graphical`.
///
/// On entering a continent whose map we haven't captured this session it
/// requests one with `bigmap noself` (no `@` self-marker — the panel draws
/// the player from GMCP coords) and swallows that response. A bigmap the
/// *user* asks for is left in the output (only the `{bigmap}` marker lines
/// are hidden), exactly like the reference plugin.
public struct ContinentBigmap: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.bigmap",
        name: "Continent Bigmap",
        author: "Proteles",
        version: "1.0",
        summary: "Captures Aardwolf's continent map for the Map panel while you travel overland."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Shows the continent ('bigmap') in the Map panel while you're overland, "
                + "with your position marked from GMCP. Fetches each continent's map once per "
                + "session, automatically. Type 'bigmap' yourself to see it in the main output."
        )
    }

    /// Aardwolf telnet option that brackets `bigmap` output with `{bigmap}` tags.
    private static let telnetOptionBigmap = 2
    /// States where a `bigmap noself` request is safe — same gating as the
    /// ASCII map's `map` requests (never during login/notes/combat).
    private static let requestStates: Set<Int> = [3, 11]

    private struct StatusState: Decodable { let state: Int? }

    /// An in-flight capture (between the `{bigmap}` marker and `{/bigmap}`).
    private struct Capture {
        let zone: Int
        let name: String
        var lines: [Line] = []
    }

    /// Capture state: nil when idle; set from the `{bigmap}` marker once a
    /// requested map starts arriving.
    private var capture: Capture?
    /// Set after we send `bigmap noself`, so we know the next `{bigmap}`
    /// block is ours to swallow (a user-typed `bigmap` stays visible).
    private var awaitingMap = false
    /// Continent zones fetched this session.
    private var fetchedZones: Set<Int> = []
    private var playing = false

    public init() {}

    public func connect() -> [ScriptEffect] {
        [.aardwolfTelnet(option: Self.telnetOptionBigmap, on: true)]
    }

    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        let text = line.text
        if text.hasPrefix("{bigmap}") {
            // `{bigmap}<zone>,<name>` — start capturing if we asked for it;
            // either way the marker itself is hidden.
            if awaitingMap, let header = Self.parseHeader(text) {
                capture = Capture(zone: header.zone, name: header.name)
            }
            return .init(gag: true)
        }
        if text == "{/bigmap}" {
            defer { capture = nil }
            if let capture {
                awaitingMap = false
                let stripped = Self.stripBorders(capture.lines)
                return .init(gag: true, effects: [
                    .updateBigmap(zone: capture.zone, name: capture.name, lines: stripped)
                ])
            }
            return .init(gag: true)
        }
        guard capture != nil else { return .init() }
        capture?.lines.append(line)
        return .init(gag: true)
    }

    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        switch package.lowercased() {
        case "char.status":
            let state = (try? JSONDecoder().decode(StatusState.self, from: Data(json.utf8)))?.state
            playing = state.map(Self.requestStates.contains) ?? false
            return []
        case "room.info":
            guard playing,
                  let info = try? JSONDecoder().decode(RoomInfo.self, from: Data(json.utf8)),
                  let coord = info.coord, coord.cont == 1,
                  let zone = coord.id, zone != -1,
                  !fetchedZones.contains(zone)
            else { return [] }
            fetchedZones.insert(zone)
            awaitingMap = true
            return [.send("bigmap noself")]
        default:
            return []
        }
    }

    /// Parse `{bigmap}<zone>,<name>` (reference trigger:
    /// `^\{bigmap\}(?<zone>\d+)\,(?<zonename>.+)$`).
    static func parseHeader(_ text: String) -> (zone: Int, name: String)? {
        let payload = text.dropFirst("{bigmap}".count)
        guard let comma = payload.firstIndex(of: ","),
              let zone = Int(payload[..<comma])
        else { return nil }
        let name = String(payload[payload.index(after: comma)...])
        guard !name.isEmpty else { return nil }
        return (zone, name)
    }

    /// Drop the bigmap's frame, mirroring the reference's `map_redirect`: the
    /// first and last rows are borders, and each remaining row loses a
    /// leading and trailing `|`. The result is the bare grid GMCP coords
    /// index into (cell (x, y) = the player).
    static func stripBorders(_ lines: [Line]) -> [Line] {
        guard lines.count > 2 else { return [] }
        return lines.dropFirst().dropLast().map { line in
            var text = line.text
            var lower = 0
            if text.hasPrefix("|") {
                text.removeFirst()
                lower = 1
            }
            var upper = lower + text.utf16.count
            if text.hasSuffix("|") {
                text.removeLast()
                upper -= 1
            }
            // Re-clip the style runs to the trimmed span, shifting left.
            let runs: [StyledRun] = line.runs.compactMap { run in
                let clipped = run.utf16Range.clamped(to: lower..<upper)
                guard !clipped.isEmpty else { return nil }
                return StyledRun(
                    utf16Range: (clipped.lowerBound - lower)..<(clipped.upperBound - lower),
                    style: run.style,
                    link: run.link
                )
            }
            return Line(id: line.id, timestamp: line.timestamp, text: text, runs: runs)
        }
    }
}
