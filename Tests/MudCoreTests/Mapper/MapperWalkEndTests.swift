import Foundation
@testable import MudCore
import Testing

/// Every `{begin running}` gets exactly one `{end running}`. The reference
/// sends its whole walk with the end at once; ours sends a segment at a time
/// with the end on the last, so a walk abandoned before then must send it.
/// The recordings had 13,218 begins with no end of their own.
@Suite("Mapper — every walk ends")
struct MapperWalkEndTests {
    private let end = ScriptEffect.sendNoEcho(Mapper.endRunningMarker)
    private let begin = ScriptEffect.sendNoEcho(Mapper.beginRunningMarker)
    private let start = #"{"num":1,"name":"Start","zone":"z","exits":{}}"#
    private let portalDest = #"{"num":14,"name":"PortalDest","zone":"z","exits":{"s":20}}"#

    /// Standing in room 1, whose only route to 20 is a portal to 14 then
    /// south: a two-segment walk, so the end waits for the second.
    private func portalMapper() async throws -> (Mapper, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-walkend-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        for json in [
            #"{"num":20,"name":"Target","zone":"z","exits":{"n":14}}"#,
            portalDest,
            start
        ] {
            _ = await mapper.ingest(package: "room.info", json: json)
        }
        _ = await mapper.handleCommand("mapper fullportal {dinv portal use 999} {14}")
        _ = await mapper.ingest(package: "room.info", json: start)
        return (mapper, url)
    }

    @Test("a two-segment walk owes its end until the last segment goes")
    func endWaitsForLastSegment() async throws {
        let (mapper, url) = try await portalMapper()
        defer { try? FileManager.default.removeItem(at: url) }
        let started = await mapper.handleCommand("mapper goto 20")
        #expect(started.contains(begin))
        #expect(!started.contains(end))
        _ = await mapper.ingest(package: "room.info", json: portalDest)
        #expect(await mapper.advanceWalk() == [.execute("run s"), end])
        // Owed no longer: cancelling now sends nothing more.
        #expect(await mapper.cancelWalk().isEmpty)
    }

    @Test("mapper stop ends a walk mid-way, once")
    func stopEnds() async throws {
        let (mapper, url) = try await portalMapper()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await mapper.handleCommand("mapper goto 20")
        let stopped = await mapper.handleCommand("mapper stop")
        #expect(stopped.contains(end))
        let again = await mapper.handleCommand("mapper stop")
        #expect(!again.contains(end))
    }

    @Test("a walk replaced mid-way ends before the new one begins")
    func replacedWalkEndsFirst() async throws {
        let (mapper, url) = try await portalMapper()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await mapper.handleCommand("mapper goto 20")
        let again = await mapper.handleCommand("mapper goto 20")
        let endAt = try #require(again.firstIndex(of: end))
        let beginAt = try #require(again.firstIndex(of: begin))
        #expect(endAt < beginAt)
    }

    @Test("a failed move cancels the walk: its end goes out, its next segment never does")
    func failedMoveCancels() async throws {
        let (mapper, url) = try await portalMapper()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await mapper.handleCommand("mapper goto 20")
        #expect(Mapper.isFailedMove("Alas, you cannot go that way."))
        #expect(await mapper.isWalking)
        #expect(await mapper.cancelWalk() == [end])
        let walking = await mapper.isWalking
        #expect(!walking)
        // Arriving where the walk was heading later releases nothing.
        _ = await mapper.ingest(package: "room.info", json: portalDest)
        #expect(await mapper.advanceWalk().isEmpty)
    }

    /// The player reached the target another way while segments were still
    /// to go (moving by hand, or a map the server disagrees with): the walk
    /// is over, so it ends now, and a later visit to a planned room releases
    /// nothing. The recordings' replay had 92 such walks on the recorded
    /// route, the end owed until the next walk.
    @Test("reaching the target before the last segment ends the walk there")
    func earlyArrivalEnds() async throws {
        let (mapper, url) = try await portalMapper()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await mapper.handleCommand("mapper goto 20")
        let target = #"{"num":20,"name":"Target","zone":"z","exits":{"n":14}}"#
        _ = await mapper.ingest(package: "room.info", json: target)
        #expect(await mapper.advanceWalk() == [end, .walkCompleted(uid: "20")])
        #expect(await !mapper.isWalking)
        _ = await mapper.ingest(package: "room.info", json: portalDest)
        #expect(await mapper.advanceWalk().isEmpty)
    }

    @Test("the reference's cancel lines, and only those")
    func failedMoveLines() {
        for line in [
            "The door is locked.",
            "You are regaining balance and are unable to move.",
            "You fumble about drunkenly.",
            "You must be standing first.",
            "You need to use a boat, fly, or swim underwater to go there.",
            "There is no exit in that direction.",
            "Alas, you cannot go that way.",
            "You can't do that while sitting.",
            "You dream about being able to walk."
        ] {
            #expect(Mapper.isFailedMove(line), "\(line)")
        }
        for line in ["The door is closed.", "Magic walls bounce you back.", "Alas, you cannot go that way"] {
            #expect(!Mapper.isFailedMove(line), "\(line)")
        }
    }
}
