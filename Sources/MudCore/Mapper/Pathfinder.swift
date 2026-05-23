import Collections
import Foundation

/// One step of a route: the command/`dir` to issue and the destination uid.
/// Matches the `{dir, uid}` shape the MUSHclient mapper uses, so it feeds
/// ``Speedwalk`` and ``StepWalker`` directly.
public struct PathStep: Sendable, Equatable {
    public let dir: String
    public let uid: String

    public init(dir: String, uid: String) {
        self.dir = dir
        self.uid = uid
    }
}

/// Routes between rooms over a ``RoomGraph`` (PLAN.md §7.7).
///
/// Dijkstra (uniform hop cost by default; honours a per-exit ``Exit/weight``
/// override) over the in-memory graph — fast at the live ~30k-room scale and
/// pure/testable. Models Aardwolf's specials faithfully:
///   - per-exit level gates (`exit.level <= level`; portals/recalls use
///     `level + tier*10`, matching the tier bonus),
///   - **portals/recalls as "from-anywhere" edges**: from any room that
///     isn't `noportal`/`norecall`, the portal `*` / recall `**` pseudo-room
///     exits become available. Because Dijkstra also explores walking edges,
///     a `noportal` start naturally walks to the nearest portal-allowed room
///     first — i.e. the original's `findNearestJumpRoom`, for free.
public struct Pathfinder: Sendable {
    public struct Options: Sendable {
        public var level: Int
        public var tier: Int
        public var allowPortals: Bool
        public var allowRecalls: Bool
        /// Cost cap to bound exploration on huge graphs (the original capped
        /// BFS depth at 300).
        public var maxCost: Int

        public init(
            level: Int = 0,
            tier: Int = 0,
            allowPortals: Bool = true,
            allowRecalls: Bool = true,
            maxCost: Int = 500
        ) {
            self.level = level
            self.tier = tier
            self.allowPortals = allowPortals
            self.allowRecalls = allowRecalls
            self.maxCost = maxCost
        }
    }

    private let graph: RoomGraph

    public init(graph: RoomGraph) {
        self.graph = graph
    }

    /// Shortest route from `src` to `dst`, or `nil` if unreachable. An empty
    /// array means src == dst (already there).
    public func path(from src: String, to dst: String, options: Options = .init()) -> [PathStep]? {
        guard src != dst else { return [] }

        var dist: [String: Int] = [src: 0]
        var parent: [String: (from: String, step: PathStep)] = [:]
        var heap = Heap<Node>()
        heap.insert(Node(cost: 0, uid: src))

        while let node = heap.popMin() {
            if node.cost > (dist[node.uid] ?? .max) { continue } // stale
            if node.uid == dst { break } // finalized at minimal cost
            if node.cost >= options.maxCost { continue }
            for edge in edges(from: node.uid, options: options) {
                let next = node.cost + edge.cost
                if next < (dist[edge.to] ?? .max) {
                    dist[edge.to] = next
                    parent[edge.to] = (from: node.uid, step: PathStep(dir: edge.dir, uid: edge.to))
                    heap.insert(Node(cost: next, uid: edge.to))
                }
            }
        }

        guard dist[dst] != nil else { return nil }
        var steps: [PathStep] = []
        var current = dst
        while current != src {
            guard let link = parent[current] else { return nil }
            steps.append(link.step)
            current = link.from
        }
        return steps.reversed()
    }

    // MARK: - Edges

    private struct Edge {
        let dir: String
        let to: String
        let cost: Int
    }

    private struct Node: Comparable {
        let cost: Int
        let uid: String

        static func < (lhs: Node, rhs: Node) -> Bool {
            lhs.cost != rhs.cost ? lhs.cost < rhs.cost : lhs.uid < rhs.uid
        }
    }

    /// Edges leaving `uid`: its own (level-gated) exits, plus portal/recall
    /// pseudo-room exits when the room permits them.
    private func edges(from uid: String, options: Options) -> [Edge] {
        // Don't expand the pseudo-rooms themselves.
        guard uid != RoomGraph.portalUID, uid != RoomGraph.recallUID,
              let room = graph.rooms[uid]
        else { return [] }

        var result: [Edge] = []
        for (dir, exit) in room.exits where Self.isUsable(exit.to) && exit.level <= options.level {
            result.append(Edge(dir: dir, to: exit.to, cost: exit.weight ?? 1))
        }
        let jumpLevel = options.level + options.tier * 10
        if options.allowPortals, !room.noportal {
            appendJumpEdges(RoomGraph.portalUID, jumpLevel: jumpLevel, into: &result)
        }
        if options.allowRecalls, !room.norecall {
            appendJumpEdges(RoomGraph.recallUID, jumpLevel: jumpLevel, into: &result)
        }
        return result
    }

    private func appendJumpEdges(_ pseudoUID: String, jumpLevel: Int, into result: inout [Edge]) {
        guard let pseudo = graph.rooms[pseudoUID] else { return }
        for (dir, exit) in pseudo.exits where Self.isUsable(exit.to) && exit.level <= jumpLevel {
            result.append(Edge(dir: dir, to: exit.to, cost: exit.weight ?? 1))
        }
    }

    /// `"0"`/empty destinations are "unknown" links (the MUD hasn't told us
    /// where they go) and can't be routed through.
    private static func isUsable(_ to: String) -> Bool {
        !to.isEmpty && to != "0"
    }
}
