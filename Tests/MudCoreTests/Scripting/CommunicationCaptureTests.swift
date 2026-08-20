import Foundation
@testable import MudCore
import Testing

@Suite("Communication Capture — Aardwolf package parity")
struct CommunicationCaptureTests {
    private func line(_ text: String, foreground: ANSIColor? = nil) -> Line {
        let runs = foreground.map {
            [StyledRun(
                utf16Range: 0..<text.utf16.count,
                style: StyleAttributes(foreground: $0)
            )]
        } ?? []
        return Line(id: LineID(1), text: text, runs: runs)
    }

    @Test("classifies all exact non-channel trigger families")
    func triggerFamilies() {
        let cases: [(String, NonChannelKind)] = [
            ("INFO: Aardwolf is rebooting", .info),
            ("RAIDINFO: the raid begins", .raidInfo),
            ("CLANINFO: a clan event", .clanInfo),
            ("Global Quest: begins in 2 minutes", .globalQuest),
            ("WARFARE: a war has started", .warfare),
            ("GENOCIDE: prepare yourselves", .warfare),
            ("Remort Auction: an item is listed", .remortAuction)
        ]
        for (text, expected) in cases {
            #expect(CommunicationCapture.classify(line(text)) == expected)
        }
        #expect(CommunicationCapture.classify(line("INFO:")) == nil)
        #expect(CommunicationCapture.classify(line("Global Quest:")) == nil)
    }

    @Test("remote-social color gate and package exclusions are exact")
    func remoteSocials() {
        #expect(CommunicationCapture.classify(line("*Bob waves happily.")) == .remoteSocials)
        #expect(CommunicationCapture.classify(
            line("*Bob waves happily.", foreground: .named(.white))
        ) == .remoteSocials)
        #expect(CommunicationCapture.classify(
            line("*Bob waves happily.", foreground: .named(.cyan))
        ) == .remoteSocials)
        #expect(CommunicationCapture.classify(
            line("*Bob waves happily.", foreground: .brightNamed(.magenta))
        ) == .remoteSocials)
        #expect(CommunicationCapture.classify(
            line("*Bob waves happily.", foreground: .named(.red))
        ) == nil)
        #expect(CommunicationCapture.classify(
            line("*Crash*, the door smashes open.")
        ) == nil)
        #expect(CommunicationCapture.classify(
            line("*Purchase using 'buy <keywords without spaces>'")
        ) == nil)
        #expect(CommunicationCapture.classify(line("** NOTE: remember this")) == nil)
        #expect(CommunicationCapture.classify(line("** Task Hint: go north")) == nil)
        #expect(CommunicationCapture.classify(line("** Goal Added: explore")) == nil)
        #expect(CommunicationCapture.classify(line("*Bob waves*")) == nil)
    }

    @Test("muted channel and disabled clan-donation capture are suppressed")
    func gmcpAdmission() {
        let policy = CommunicationPolicyStore()
        policy.setCapture(false, source: .nonChannel(.clanDonations))
        var plugin = CommunicationCapture(policy: policy)
        let comm = CommChannel(
            chan: "claninfo",
            msg: "CLAN ANNOUNCEMENT: Homer has donated 10 quest points",
            player: "Homer"
        )
        let donation = GMCPDispatchContext(
            communication: comm,
            communicationLine: line(AardwolfColor.stripped(comm.msg)),
            isClanDonation: true
        )
        #expect(plugin.onGMCP(package: "comm.channel", json: "", context: donation).isEmpty)

        policy.setCapture(true, source: .nonChannel(.clanDonations))
        var muted = donation
        muted.speakerMuted = true
        #expect(plugin.onGMCP(package: "comm.channel", json: "", context: muted).isEmpty)
        #expect(plugin.onGMCP(package: "comm.channel", json: "", context: donation).count == 1)
    }

    @Test("capture and main-output echo controls remain independent")
    func independentPolicies() {
        let policy = CommunicationPolicyStore()
        policy.setEcho(false, source: .nonChannel(.info))
        let plugin = CommunicationCapture(policy: policy)
        let capturedButGagged = plugin.onLine(line("INFO: test"))
        #expect(capturedButGagged.gag)
        #expect(capturedButGagged.effects.count == 1)

        policy.setCapture(false, source: .nonChannel(.info))
        let neither = plugin.onLine(line("INFO: test"))
        #expect(neither.gag)
        #expect(neither.effects.isEmpty)
    }

    @Test("registry filters GMCP through Text Substitution before capture and echo")
    func substitutionOrdering() {
        let policy = CommunicationPolicyStore()
        var textSub = TextSubstitution()
        _ = textSub.handleCommand("#sub {original} {changed}")
        var registry = NativePluginRegistry()
        registry.register(textSub)
        registry.register(CommunicationCapture(policy: policy))
        registry.register(ChatEcho(policy: policy))
        let effects = registry.onGMCP(
            package: "comm.channel",
            json: #"{"chan":"chat","msg":"original","player":"Bob"}"#
        )
        let texts = effects.compactMap { effect -> String? in
            switch effect {
            case .communicationCapture(_, _, let line, _, _), .echoLine(let line): line.text
            default: nil
            }
        }
        #expect(texts == ["changed", "changed"])
    }

    @Test("note mode buffers main echoes and releases them on exit")
    func noteModeBuffering() {
        var plugin = ChatEcho()
        _ = plugin.onGMCP(package: "char.status", json: #"{"state":5}"#)
        #expect(plugin.onGMCP(
            package: "comm.channel",
            json: #"{"chan":"tell","msg":"held tell","player":"Bob"}"#
        ).isEmpty)
        let released = plugin.onGMCP(package: "char.status", json: #"{"state":3}"#)
        #expect(released.count == 2)
        guard case .echoLine(let echoed) = released.last else {
            Issue.record("buffered line was not echoed"); return
        }
        #expect(echoed.text == "held tell")
    }
}
