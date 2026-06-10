import Foundation
@testable import MudCore
import Testing

/// #53 — the version-skew fix. The packaged release shipped a current
/// `Search_and_Destroy.xml` beside a stale pre-split `core.lua`; the host
/// armed the XML's aliases but ran the old core's functions, so commands
/// added upstream (`xset autonav`, `ht find`, `mobsearch`) fired into nil.
/// Now the XML's `<script>` CDATA is the source of truth (core.lua is the
/// fallback) and the `[Proteles bridge]` is injected at LOAD time, so it
/// rides any S&D source. The bundled fixture intentionally mirrors the
/// shipped skew (its XML has autonav, its core.lua doesn't) — these tests
/// fail on the old core-first load path.
@Suite("Search-and-Destroy — XML source of truth + bridge injection (#53)")
struct SnDSourceAndBridgeTests {
    init() {
        SnDFixture.install()
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { return segs.map(\.text).joined() }
            if case .note(let text, _, _) = $0 { return text }
            if case .echo(let text) = $0 { return text }
            return nil
        }
    }

    // MARK: - The skew regression: commands newer than the split core

    @Test("xset autonav toggles (the reported dead command)")
    func autonavToggles() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        let on = try #require(await host.expandCommand("xset autonav"))
        #expect(notes(on).contains { $0.contains("Auto-navigate") && $0.contains("ON") })
        let off = try #require(await host.expandCommand("xset autonav"))
        #expect(notes(off).contains { $0.contains("Auto-navigate") && $0.contains("OFF") })
        // (Cross-restart persistence of mcvar_xset_autonav_onoff rides the
        // S&D variable-persistence work — issue #52, not this fix.)
    }

    @Test("ht find (also post-split) answers instead of firing into nil")
    func htFindAnswers() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        let effects = try #require(await host.expandCommand("ht find"))
        #expect(notes(effects).contains { $0.contains("no previous hunt") })
    }

    // MARK: - Bridge injection

    @Test("the bridge injects after the anchor for LF and CRLF sources alike")
    func injectionHandlesLineEndings() {
        for terminator in ["\n", "\r\n"] {
            let source = "local x = 1" + terminator
                + "function xg_draw_window()" + terminator
                + "    original_first_statement()" + terminator
                + "end" + terminator
            let injected = SearchAndDestroyHost.injectingBridge(into: source)
            #expect(injected.contains("[Proteles bridge]"))
            // The original first statement survives on its own line (the
            // bridge's last line ends in a `--` comment — a missing newline
            // would swallow it).
            #expect(injected.contains("    original_first_statement()"))
            let bridgeAt = try? #require(injected.range(of: "[Proteles bridge]"))
            let originalAt = try? #require(injected.range(of: "original_first_statement"))
            if let bridgeAt, let originalAt {
                #expect(bridgeAt.lowerBound < originalAt.lowerBound)
            }
        }
    }

    @Test("injection is idempotent and tolerates a missing anchor")
    func injectionGuards() {
        let baked = "function xg_draw_window()\n    -- [Proteles bridge] already here\nend\n"
        #expect(SearchAndDestroyHost.injectingBridge(into: baked) == baked)
        let anchorless = "function something_else()\nend\n"
        #expect(SearchAndDestroyHost.injectingBridge(into: anchorless) == anchorless)
    }

    @Test("the loaded host still publishes the panel model (bridge alive on the XML source)")
    func bridgePublishesOnXMLSource() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // Drive xg_draw_window directly; the injected bridge publishes JSON.
        let effects = try await host.run("xg_draw_window()")
        let published = effects.contains {
            if case .publishModel = $0 { true } else { false }
        }
        #expect(published)
    }
}
