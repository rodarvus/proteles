import Foundation
@testable import MudCore
import Testing

@Suite("Pathfinder — routing")
struct PathfinderTests {
    /// Build a graph from (uid, [dir: (dest, level)]) tuples.
    private func graph(
        _ rooms: [String: [String: (String, Int)]],
        portals: [String: String] = [:],
        recalls: [String: String] = [:],
        noportal: Set<String> = []
    ) -> RoomGraph {
        var g = RoomGraph()
        for (uid, exits) in rooms {
            var room = Room(uid: uid, name: uid, noportal: noportal.contains(uid))
            for (dir, dest) in exits {
                room.exits[dir] = Exit(dir: dir, to: dest.0, level: dest.1)
            }
            g.rooms[uid] = room
        }
        if !portals.isEmpty {
            var portalRoom = Room(uid: RoomGraph.portalUID)
            for (cmd, dest) in portals {
                portalRoom.exits[cmd] = Exit(dir: cmd, to: dest)
            }
            g.rooms[RoomGraph.portalUID] = portalRoom
        }
        if !recalls.isEmpty {
            var r = Room(uid: RoomGraph.recallUID)
            for (cmd, dest) in recalls {
                r.exits[cmd] = Exit(dir: cmd, to: dest)
            }
            g.rooms[RoomGraph.recallUID] = r
        }
        return g
    }

    @Test("Finds a simple linear path; src==dst is empty; unreachable is nil")
    func linear() {
        let pf = Pathfinder(graph: graph([
            "1": ["n": ("2", 0)], "2": ["n": ("3", 0)], "3": [:], "9": [:]
        ]))
        #expect(pf.path(from: "1", to: "3")?.map(\.dir) == ["n", "n"])
        #expect(pf.path(from: "1", to: "3")?.map(\.uid) == ["2", "3"])
        #expect(pf.path(from: "1", to: "1")?.isEmpty == true)
        #expect(pf.path(from: "1", to: "9") == nil) // disconnected
    }

    @Test("Chooses the fewest-hops route when branches differ")
    func shortest() {
        // 1→2→4 (2 hops) vs 1→3→…→4 (longer). Direct should win.
        let pf = Pathfinder(graph: graph([
            "1": ["n": ("2", 0), "s": ("3", 0)],
            "2": ["e": ("4", 0)],
            "3": ["e": ("5", 0)], "5": ["e": ("4", 0)],
            "4": [:]
        ]))
        #expect(pf.path(from: "1", to: "4")?.count == 2)
        #expect(pf.path(from: "1", to: "4")?.first?.dir == "n")
    }

    @Test("Exits above the character level are excluded")
    func levelGate() {
        let pf = Pathfinder(graph: graph([
            "1": ["n": ("2", 200)], "2": [:]
        ]))
        #expect(pf.path(from: "1", to: "2", options: .init(level: 100)) == nil)
        #expect(pf.path(from: "1", to: "2", options: .init(level: 200))?.count == 1)
    }

    @Test("Portals are from-anywhere edges; disabling them forces a walk")
    func portals() {
        // 1→2 (walk). A portal jumps straight to 99 from anywhere.
        let pf = Pathfinder(graph: graph(
            ["1": ["n": ("2", 0)], "2": [:], "99": [:]],
            portals: ["enter portal": "99"]
        ))
        // With portals, reach 99 in one step from room 1.
        let viaPortal = pf.path(from: "1", to: "99")
        #expect(viaPortal?.count == 1)
        #expect(viaPortal?.first?.dir == "enter portal")
        // Without portals, 99 is unreachable.
        #expect(pf.path(from: "1", to: "99", options: .init(allowPortals: false)) == nil)
    }

    @Test("A noportal room walks to the nearest portal-allowed room first")
    func noportalWalksToJumpRoom() {
        // Room 1 is noportal; room 2 can portal to 99. Path: walk 1→2, then portal.
        let pf = Pathfinder(graph: graph(
            ["1": ["n": ("2", 0)], "2": [:], "99": [:]],
            portals: ["enter portal": "99"],
            noportal: ["1"]
        ))
        let path = pf.path(from: "1", to: "99")
        #expect(path?.map(\.dir) == ["n", "enter portal"])
    }

    @Test("A custom-exit command is preferred over a coincident cardinal exit")
    func customExitPreferredOverCardinal() {
        // Petting-zoo room 986 has BOTH a GMCP `w` and a player cexit
        // `open west;west` to room 1028 — the cexit opens a warded door the bare
        // `w` bounces off. The two exits must collapse to the cexit, not the `w`.
        var room = Room(uid: "986")
        room.exits["w"] = Exit(dir: "w", to: "1028")
        room.exits["open west;west"] = Exit(dir: "open west;west", to: "1028")
        let toDest = Pathfinder.ownEdges(of: room, level: 0).filter { $0.to == "1028" }
        #expect(toDest.count == 1) // collapsed to a single edge
        #expect(toDest.first?.dir == "open west;west") // …and it's the cexit
    }

    @Test("Routing through a cardinal+cexit pair uses the cexit, not the bare direction")
    func routePrefersCustomExit() {
        // End-to-end: A -s-> B, and B reaches D by both `w` and `open west;west`.
        // The speedwalk must end with the cexit command, not a bare `w` that
        // would bounce off the closed door and strand the walk in B.
        var roomA = Room(uid: "A")
        roomA.exits["s"] = Exit(dir: "s", to: "B")
        var roomB = Room(uid: "B")
        roomB.exits["w"] = Exit(dir: "w", to: "D")
        roomB.exits["open west;west"] = Exit(dir: "open west;west", to: "D")
        var g = RoomGraph()
        g.rooms["A"] = roomA
        g.rooms["B"] = roomB
        g.rooms["D"] = Room(uid: "D")
        let path = Pathfinder(graph: g).path(from: "A", to: "D")
        #expect(path?.map(\.dir) == ["s", "open west;west"])
    }
}

@Suite("Speedwalk + StepWalker")
struct SpeedwalkTests {
    private func steps(_ pairs: [(String, String)]) -> [PathStep] {
        pairs.map { PathStep(dir: $0.0, uid: $0.1) }
    }

    @Test("Runs of compass dirs compress with the run prefix")
    func compress() {
        let path = steps([("n", "2"), ("n", "3"), ("n", "4"), ("e", "5"), ("e", "6")])
        #expect(Speedwalk.build(path) == "run 3n2e")
    }

    @Test("A custom command breaks the run and re-prefixes the next leg")
    func customExit() {
        let path = steps([("n", "2"), ("n", "3"), ("enter portal", "50"), ("e", "51")])
        #expect(Speedwalk.build(path) == "run 2n;enter portal;run e")
    }

    @Test("Diagonals are emitted standalone (run can't pack them)")
    func diagonals() {
        let path = steps([("n", "2"), ("ne", "3"), ("n", "4")])
        #expect(Speedwalk.build(path) == "run n;ne;run n")
    }

    @Test("StepWalker sends each step, verifying arrival, then completes")
    func stepWalker() {
        var walker = StepWalker(path: steps([("n", "2"), ("e", "3")]))
        #expect(walker.start() == .send("n"))
        #expect(walker.roomEntered("2") == .send("e"))
        #expect(walker.roomEntered("3") == .completed)
        #expect(walker.isFinished)
    }

    @Test("StepWalker aborts when arriving at the wrong room")
    func stepWalkerWrongRoom() {
        var walker = StepWalker(path: steps([("n", "2"), ("e", "3")]))
        _ = walker.start()
        if case .failed = walker.roomEntered("99") {} else {
            Issue.record("expected failure on wrong room")
        }
    }

    @Test("An empty path completes immediately")
    func emptyPath() {
        var walker = StepWalker(path: [])
        #expect(walker.start() == .completed)
    }
}
