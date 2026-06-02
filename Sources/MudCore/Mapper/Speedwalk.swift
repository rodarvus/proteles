import Foundation

/// Turns a route (``PathStep`` list) into a speedwalk command string — a
/// faithful port of `aard_GMCP_mapper`'s `build_speedwalk`.
///
/// Runs of the single-character compass directions Aardwolf's `run` command
/// understands (`n/s/e/w/u/d`) collapse into `count+dir` (e.g. `3n2e`) and
/// are prefixed with the run command. Anything else — diagonals (`ne`/`sw`/…,
/// which `run` can't pack) and custom-exit commands (`enter portal`) — is
/// emitted as its own stacked command, and the next compass run is
/// re-prefixed.
public enum Speedwalk {
    /// Single-char directions that pack into the `run` string. Diagonals
    /// can't (Aardwolf's run parses one char per step), so they stay
    /// standalone.
    static let runnable: Set<String> = ["n", "s", "e", "w", "u", "d"]

    /// One emitted speedwalk segment: the command to send and the room uid we
    /// expect to be in once it completes (the uid of the last ``PathStep`` it
    /// covers). The expected-uid is what lets the walker WAIT for a portal/special
    /// step to land before sending the next segment (otherwise a follow-on `run`
    /// races the portal — see ``Mapper`` `advanceWalk`).
    public struct Segment: Sendable, Equatable {
        public let command: String
        public let expectUID: String
        public init(command: String, expectUID: String) {
            self.command = command
            self.expectUID = expectUID
        }
    }

    /// The speedwalk as discrete commands to send in order — e.g.
    /// `["run 3n2e", "enter portal", "run e"]`. Proteles has no client-side
    /// `;` stacking, so the command surface sends these one at a time.
    public static func commands(_ path: [PathStep], prefix: String = "run") -> [String] {
        segments(path, prefix: prefix).map(\.command)
    }

    /// Like ``commands(_:prefix:)`` but each segment also carries the room uid it
    /// should land in. Runs of single-char compass dirs collapse into one
    /// `prefix <packed>` segment (expecting the run's final room); a diagonal or
    /// custom-exit command (e.g. a `dinv portal use …` hop) is its own segment
    /// (expecting that step's destination).
    public static func segments(_ path: [PathStep], prefix: String = "run") -> [Segment] {
        var result: [Segment] = []
        var move = ""
        var moveLastUID = ""
        func flushMove() {
            guard !move.isEmpty else { return }
            result.append(Segment(
                command: prefix.isEmpty ? move : "\(prefix) \(move)",
                expectUID: moveLastUID
            ))
            move = ""
            moveLastUID = ""
        }
        /// True while the step at `next` continues the current run of `dir`.
        func continuesRun(_ next: Int, _ dir: String) -> Bool {
            next < path.count && path[next].dir == dir && runnable.contains(dir)
        }
        var index = 0
        while index < path.count {
            let step = path[index]
            if runnable.contains(step.dir) {
                // Run-length compress consecutive identical runnable dirs.
                var count = 1
                moveLastUID = step.uid
                while continuesRun(index + 1, step.dir) {
                    count += 1
                    index += 1
                    moveLastUID = path[index].uid
                }
                move += (count > 1 ? String(count) : "") + step.dir
            } else {
                flushMove()
                result.append(Segment(command: step.dir, expectUID: step.uid))
            }
            index += 1
        }
        flushMove()
        return result
    }

    /// The speedwalk as one string, segments joined by `stackChar` (for
    /// display / tests).
    public static func build(_ path: [PathStep], prefix: String = "run", stackChar: String = ";") -> String {
        commands(path, prefix: prefix).joined(separator: stackChar)
    }
}

/// Drives a route one step at a time, verifying arrival against incoming
/// `room.info` — the safe walker (the original's step-verifying mode). Each
/// step sends its command, then waits for the room uid to match before
/// sending the next; a mismatch aborts. A pure value type so it's testable
/// without a session.
public struct StepWalker: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// Send this command to the MUD.
        case send(String)
        /// The route finished successfully.
        case completed
        /// We arrived somewhere off-route; the walk is aborted.
        case failed(String)
    }

    private let steps: [PathStep]
    private var index: Int
    /// The uid we expect after the most recently sent step.
    private var expecting: String?

    public init(path: [PathStep]) {
        steps = path
        index = 0
        expecting = nil
    }

    /// Begin the walk: the first command to send (or `.completed` if empty).
    public mutating func start() -> Event {
        guard index < steps.count else { return .completed }
        expecting = steps[index].uid
        return .send(steps[index].dir)
    }

    /// Call when a `room.info` for `uid` arrives. Advances to the next step,
    /// completes, or fails on a wrong room.
    public mutating func roomEntered(_ uid: String) -> Event {
        guard let expecting else { return .completed }
        guard uid == expecting else {
            return .failed("Speedwalk failed — expected room \(expecting), arrived at \(uid).")
        }
        index += 1
        guard index < steps.count else {
            self.expecting = nil
            return .completed
        }
        self.expecting = steps[index].uid
        return .send(steps[index].dir)
    }

    public var isFinished: Bool {
        expecting == nil && index >= steps.count
    }
}
