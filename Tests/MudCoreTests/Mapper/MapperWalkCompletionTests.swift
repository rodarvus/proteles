import Foundation
@testable import MudCore
import Testing

/// The arrival-gated walk-completion signal that backs "hold a command after
/// `mapper goto` until you land" (the F9/F10/F11 `goto X` ⏎ `quest …` fix). A
/// walk arms ``Mapper/walkArmGeneration`` + ``Mapper/isWalking`` and emits
/// `.walkCompleted` only when the FINAL destination's `room.info` arrives — for
/// every route shape, including a recall/home/portal first jump.
@Suite("Mapper — walk completion signal")
struct MapperWalkCompletionTests {
    /// Linear map 1 —e→ 2 —e→ 3, one area.
    private func makeMapper() async throws -> Mapper {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-walkdone-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"One","zone":"aylor","exits":{"e":2}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Two","zone":"aylor","exits":{"e":3,"w":1}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Three","zone":"aylor","exits":{"w":2}}"#
        )
        // Stand in room 1.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"One","zone":"aylor","exits":{"e":2}}"#
        )
        return mapper
    }

    private func arrive(_ mapper: Mapper, num: Int, exits: String) async -> [ScriptEffect] {
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":\#(num),"name":"R","zone":"aylor","exits":{\#(exits)}}"#
        )
        return await mapper.advanceWalk()
    }

    private func hasCompletion(_ effects: [ScriptEffect], uid: String) -> Bool {
        effects.contains { if case .walkCompleted(let dest) = $0 { dest == uid } else { false } }
    }

    @Test("goto arms isWalking + bumps the arm generation; arrival clears it")
    func armAndClear() async throws {
        let mapper = try await makeMapper()
        let armBefore = await mapper.walkArmGeneration
        #expect(await mapper.isWalking == false)

        _ = await mapper.handleCommand("mapper goto 3")
        #expect(await mapper.isWalking == true)
        #expect(await mapper.walkArmGeneration == armBefore + 1)

        // Arrival at the target 3 ends the walk and signals completion.
        let effects = await arrive(mapper, num: 3, exits: #""w":2"#)
        #expect(hasCompletion(effects, uid: "3"))
        #expect(await mapper.isWalking == false)
    }

    @Test("completion fires only at the final target — not at an intermediate room")
    func completionOnlyAtTarget() async throws {
        let mapper = try await makeMapper()
        // A path with a non-runnable middle step forces >1 segment so an
        // intermediate room.info is actually consulted.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"One","zone":"aylor","exits":{"e":2}}"#
        )
        _ = await mapper.handleCommand("mapper goto 3")

        // Arriving at intermediate room 2 must NOT complete the walk.
        let mid = await arrive(mapper, num: 2, exits: #""e":3,"w":1"#)
        #expect(hasCompletion(mid, uid: "3") == false)
        #expect(await mapper.isWalking == true)

        // Arriving at the target completes it.
        let end = await arrive(mapper, num: 3, exits: #""w":2"#)
        #expect(hasCompletion(end, uid: "3"))
        #expect(await mapper.isWalking == false)
    }

    @Test("recall and home route steps are identical standalone gated segments")
    func recallHomeSegmentsIdentical() {
        for jump in ["recall", "home"] {
            let path = [
                PathStep(dir: jump, uid: "100"), // the teleport (non-runnable)
                PathStep(dir: "n", uid: "101"),
                PathStep(dir: "e", uid: "102")
            ]
            let segments = Speedwalk.segments(path)
            // The teleport is its own segment expecting the recall/home room,
            // gating the follow-on run exactly like a portal hop — and recall and
            // home produce the SAME segment shape. (End-to-end recall deferral is
            // a separate, still-open problem — issue #78 — but it isn't a
            // segmentation difference between recall and home.)
            #expect(segments == [
                Speedwalk.Segment(command: jump, expectUID: "100"),
                Speedwalk.Segment(command: "run ne", expectUID: "102")
            ])
        }
    }

    @Test("being already at the target arms no walk (follow-up should run at once)")
    func alreadyThereNoWalk() async throws {
        let mapper = try await makeMapper()
        // Stand in room 3, then goto 3 → "already in that room", no walk.
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"Three","zone":"aylor","exits":{"w":2}}"#
        )
        let armBefore = await mapper.walkArmGeneration
        _ = await mapper.handleCommand("mapper goto 3")
        #expect(await mapper.isWalking == false)
        #expect(await mapper.walkArmGeneration == armBefore)
    }
}
