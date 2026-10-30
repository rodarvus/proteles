import Foundation
@testable import MudCore
import Testing

@Suite("FeedMarker — one parse per tag line")
struct FeedMarkerTests {
    @Test("S0b's markers parse with their feed, direction and arguments")
    func parsesFeedMarkers() {
        #expect(FeedMarker.parse("{roomchars}") == FeedMarker(
            feed: .roomchars,
            isClosing: false,
            arguments: ""
        ))
        #expect(FeedMarker.parse("{/roomchars}") == FeedMarker(
            feed: .roomchars,
            isClosing: true,
            arguments: ""
        ))
        #expect(FeedMarker.parse("{spellheaders hsp}")
            == FeedMarker(feed: .spellheaders, isClosing: false, arguments: "hsp"))
        #expect(FeedMarker.parse("{invdata 2553436219}")
            == FeedMarker(feed: .invdata, isClosing: false, arguments: "2553436219"))
        #expect(FeedMarker.parse("{exits}north east") == FeedMarker(
            feed: .exits,
            isClosing: false,
            arguments: ""
        ))
        #expect(FeedMarker.parse("{invmon}2,2553436219,-1,6")
            == FeedMarker(feed: .invmon, isClosing: false, arguments: ""))
    }

    @Test("Other tags and plain lines are not feed markers")
    func rejectsOthers() {
        for text in ["", "plain text", "{rdesc}A room.", "{coords}4,6,20", "{rname}Inside", "{invitem}1,2"] {
            #expect(FeedMarker.parse(text) == nil, "\(text)")
        }
    }

    @Test("The router's grammar stays the authority on near-misses")
    func agreesWithRouterGrammar() {
        // A longer name, an uppercase name, no closing brace, a brace inside
        // the arguments, dinv's fence: none is a tag to the router either.
        let nearMisses = [
            "{roomcharsx}", "{ROOMCHARS}", "{roomchars", "{roomchars x{y}", "{ DINV fence }",
            "{roomchars\u{301}}"
        ]
        for text in nearMisses {
            #expect(AardwolfTags.leadingTag(in: text)?.name != "roomchars", "\(text)")
            #expect(FeedMarker.parse(text) == nil, "\(text)")
        }
    }
}
