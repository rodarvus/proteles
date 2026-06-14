import Foundation
@testable import MudCore
import Testing

@Suite("ConsiderFeature — roomchars-driven refresh")
struct ConsiderFeatureTests {
    /// A feature in a playing state (state 3), with roomchars already enabled.
    private func playingFeature() -> ConsiderFeature {
        var feature = ConsiderFeature()
        _ = feature.onGMCP(package: "char.status", json: #"{"level":100,"state":3,"align":500}"#)
        return feature
    }

    private func line(_ text: String) -> Line {
        Line(id: LineID(0), text: text)
    }

    @Test("The roomchars block is gagged")
    func gagsBlock() {
        var feature = playingFeature()
        #expect(feature.onLine(line("{roomchars}")).gag)
        #expect(feature.onLine(line("(R) a goblin is here.")).gag)
        #expect(feature.onLine(line("{/roomchars}")).gag)
    }

    @Test("A new occupant set triggers a consider-all")
    func occupantChangeConsiders() {
        var feature = playingFeature()
        _ = feature.onLine(line("{roomchars}"))
        _ = feature.onLine(line("(R) a goblin is here."))
        let end = feature.onLine(line("{/roomchars}"))
        #expect(end.effects.contains(.sendNoEcho("consider all")))
    }

    @Test("An unchanged occupant set does not re-consider (heartbeat blocks)")
    func unchangedDoesNotReConsider() {
        var feature = playingFeature()
        for _ in 0..<2 {
            _ = feature.onLine(line("{roomchars}"))
            _ = feature.onLine(line("(R) a goblin is here."))
            _ = feature.onLine(line("{/roomchars}"))
        }
        // Second identical block produces no fresh consider.
        _ = feature.onLine(line("{roomchars}"))
        _ = feature.onLine(line("(R) a goblin is here."))
        let end = feature.onLine(line("{/roomchars}"))
        #expect(!end.effects.contains(.sendNoEcho("consider all")))
    }

    @Test("An occupant change while in combat defers until combat ends")
    func defersDuringCombat() {
        var feature = ConsiderFeature()
        _ = feature.onGMCP(package: "char.status", json: #"{"level":100,"state":8}"#) // fighting
        _ = feature.onLine(line("{roomchars}"))
        _ = feature.onLine(line("(R) a goblin is here."))
        let mid = feature.onLine(line("{/roomchars}"))
        #expect(!mid.effects.contains(.sendNoEcho("consider all"))) // deferred
        // Combat ends → the deferred refresh fires.
        let ended = feature.onGMCP(package: "char.status", json: #"{"level":100,"state":3}"#)
        #expect(ended.contains(.sendNoEcho("consider all")))
    }
}
