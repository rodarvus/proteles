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

    public static func build(_ path: [PathStep], prefix: String = "run", stackChar: String = ";") -> String {
        // Run-length compress consecutive runnable dirs.
        struct Run { var dir: String; var count: Int }
        var runs: [Run] = []
        for step in path {
            if var last = runs.last, runnable.contains(step.dir), last.dir == step.dir {
                last.count += 1
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(dir: step.dir, count: 1))
            }
        }

        // Assemble: runnable runs accumulate into a `prefix <runs>` segment;
        // anything else is its own segment. Segments join with `stackChar`.
        var segments: [String] = []
        var move = ""
        func flushMove() {
            guard !move.isEmpty else { return }
            segments.append(prefix.isEmpty ? move : "\(prefix) \(move)")
            move = ""
        }
        for run in runs {
            if runnable.contains(run.dir) {
                move += (run.count > 1 ? String(run.count) : "") + run.dir
            } else {
                flushMove()
                segments.append(run.dir)
            }
        }
        flushMove()
        return segments.joined(separator: stackChar)
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
