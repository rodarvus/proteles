import Foundation
@testable import MudCore
import Testing

/// Regression test against a real captured Aardwolf welcome banner.
///
/// The fixture is the first 2 chunks of a real session captured via the
/// `autoRecord` path. Together they cover the complete opening
/// handshake plus all the static, public welcome-banner content (the
/// "###" ASCII art with the dragon, the "Welcome to Aardwolf MUD"
/// title, the player count, and the "What be thy name?" prompt).
/// **Nothing past the prompt is included** — no login response, no
/// game state, no user-typed input — so the fixture has zero personally
/// identifying content and is identical-shape for every Aardwolf
/// connection.
///
/// This catches any future change that breaks the wire-format pipeline
/// in subtle ways that synthetic tests miss: real Aardwolf telnet
/// negotiation set, real zlib compression, real ANSI sequences, real
/// MUD output layout.
@Suite("Aardwolf welcome banner fixture")
struct AardwolfWelcomeBannerFixtureTests {
    @Test("Welcome banner replays cleanly through LinePipeline")
    func replayProducesExpectedBanner() throws {
        let url = try fixtureURL("aardwolf-welcome-banner", "jsonl")
        let replayer = try SessionReplayer(url: url)

        // The fixture is exactly the first 2 chunks.
        #expect(replayer.chunks.count == 2)

        var pipeline = LinePipeline()
        let output = try replayer.replay(into: &pipeline)

        // Protocol-stack assertions.
        #expect(output.compressionActivations == 1)
        #expect(pipeline.isCompressionActive)
        // Aardwolf opens with 8 option offers (WILL COMPRESS2, WILL 85,
        // WILL 102, WILL ATCP, WILL GMCP, DO 102, DO TTYPE, DO NAWS).
        // We accept MCCP2 (DO) and refuse the rest (DONT / WONT), so
        // 8 responses must be produced.
        #expect(output.responses.count == 8)

        // Content assertions — these strings appear verbatim in every
        // Aardwolf session and are stable across server upgrades.
        let allText = output.lines.map(\.text).joined(separator: "\n")
        #expect(allText.contains("--- Welcome to Aardwolf MUD ---"))
        #expect(allText.contains("Players Currently Online:"))
        #expect(allText.contains("Enter your character name or type 'NEW' to create a new character"))
        #expect(allText.contains("What be thy name, adventurer?"))

        // Line count is stable across reruns of replay (24 from this
        // fixture); guard against silent off-by-one regressions in the
        // line builder or ANSI parser.
        #expect(output.lines.count == 24)
    }

    @Test("First chunk contains the canonical opening telnet handshake")
    func openingHandshakeIsAardwolfStandard() throws {
        let url = try fixtureURL("aardwolf-welcome-banner", "jsonl")
        let replayer = try SessionReplayer(url: url)
        let first = Array(replayer.chunks[0].bytes)

        // Bytes 0..2 are `IAC WILL COMPRESS2` — the MCCP2 offer that
        // Aardwolf leads with on every connection. Catches "did we
        // accidentally break Telnet option byte interpretation?"
        #expect(first.count >= 3)
        #expect(first[0] == TelnetCommand.iac)
        #expect(first[1] == TelnetCommand.will)
        #expect(first[2] == TelnetOption.mccp2)
    }

    // MARK: - Helpers

    private func fixtureURL(
        _ name: String,
        _ ext: String
    ) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "Fixtures/\(name)",
            withExtension: ext
        ) else {
            throw FixtureError.notFound("\(name).\(ext)")
        }
        return url
    }

    enum FixtureError: Error {
        case notFound(String)
    }
}
