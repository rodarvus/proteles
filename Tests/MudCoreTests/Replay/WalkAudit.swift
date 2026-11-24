import Foundation
@testable import MudCore

/// What one replayed walk window sent and broadcast, held to the walk
/// protocol (the mapper's `{begin running}`/`{end running}` pair and the 999
/// broadcast plugins hear). Pure, so the checks are tested on hand-made
/// windows before they judge the corpus.
enum WalkAudit {
    /// How the recorded walk ended, read from the recording alone.
    enum Recorded: String, CaseIterable {
        case completed, failed, stopped, replaced, disconnected
    }

    /// One window: the client's sends and the plugins' broadcasts within it.
    struct Window {
        var sent: [String] = []
        var heard: [String] = []
        /// The replay's mapper finished (arrived, cancelled or stopped)
        /// before the window closed.
        var resolved = false
        /// A wait-bearing segment was paced: its end comes from a task of
        /// its own, after real seconds, so the window can't judge it.
        var paced = false
        /// Index in ``sent`` just after a failed move during the walk, and
        /// that walk's segments: none may go out after it.
        var cancelledAt: Int?
        var cancelledSegments: [String] = []
        /// Index in ``sent`` where the next walk was started, if any.
        var nextWalkAt: Int?
        /// A cancel line arrived while the replay was walking.
        var failedWhileWalking = false
        /// The player reached the walk's target before its last segment
        /// went out (the recording took another way there).
        var landedEarly = false
        /// The recording ended mid-walk: no end can be sent, and plugins
        /// hear the walk is over from the disconnect instead.
        var disconnected = false
        /// The window before this one paced a wait-bearing segment, whose
        /// task may still send its end here.
        var afterPaced = false
    }

    static let begin = "echo {begin running}"
    static let end = "echo {end running}"
    static let busy = "kinda_busy"
    static let free = "ok_you_can_go_now"

    /// The reference's cancel lines (`aard_GMCP_mapper.xml`), written here a
    /// second time on purpose.
    static let cancelLines: Set<String> = [
        "The door is locked.",
        "You are regaining balance and are unable to move.",
        "You fumble about drunkenly.",
        "You must be standing first.",
        "You need to use a boat, fly, or swim underwater to go there.",
        "There is no exit in that direction.",
        "Alas, you cannot go that way."
    ]

    /// The cancel line's shape, wildcards collapsed (`You can't * while
    /// sitting.`), or nil for any other line.
    static func cancelShape(_ text: String) -> String? {
        if cancelLines.contains(text) { return text }
        if text.hasPrefix("You dream about ") { return "You dream about …" }
        if text.hasPrefix("You can't "),
           text.hasSuffix(" while sitting.") { return "You can't … while sitting." }
        return nil
    }

    static func violations(_ window: Window) -> [String] {
        markerViolations(window) + failureViolations(window) + broadcastViolations(window)
    }

    /// Each begin has one end, and a finished walk owes none.
    private static func markerViolations(_ window: Window) -> [String] {
        var out: [String] = []
        var owed = false
        for line in window.sent {
            if line == begin {
                if owed {
                    let paced = window.paced ? " (a paced segment superseded mid-pause)" : ""
                    out.append("a walk began while the last still owed its end\(paced)")
                }
                owed = true
            } else if line == end {
                if !owed {
                    out
                        .append("an end with no walk to end" +
                            (window.afterPaced ? " (after a paced walk)" : ""))
                }
                owed = false
            }
        }
        if owed, window.resolved, !window.paced, !window.disconnected {
            let early = window.landedEarly ? ", having reached its target before its last segment" : ""
            out.append("the walk finished but never sent its end\(early)")
        }
        return out
    }

    /// After a failed move, the walk ends and sends nothing more.
    private static func failureViolations(_ window: Window) -> [String] {
        var out: [String] = []
        var beforeNextWalk = window
        beforeNextWalk.sent = Array(window.sent.prefix(window.nextWalkAt ?? window.sent.count))
        if window.failedWhileWalking, !window.paced, owesEnd(beforeNextWalk) {
            out.append("a failed move left the walk owing its end")
        }
        if let cancelled = window.cancelledAt {
            let until = max(cancelled, min(window.nextWalkAt ?? window.sent.count, window.sent.count))
            let after = window.sent[min(cancelled, until)..<until]
            let segments = Set(window.cancelledSegments)
            if let stray = after.first(where: segments.contains) {
                out.append("a segment went out after the move failed: \(stray)")
            }
        }
        return out
    }

    /// Plugins hear busy and free in turn, and free once the walk is over.
    private static func broadcastViolations(_ window: Window) -> [String] {
        var out: [String] = []
        for (previous, next) in zip(window.heard, window.heard.dropFirst()) where previous == next {
            out.append("plugins heard \(next) twice in a row")
        }
        if window.resolved, !window.paced, let last = window.heard.last, last != free {
            out.append("the walk finished but plugins last heard \(last)")
        }
        return out
    }

    /// Whether the window's walk still owes its end at close.
    static func owesEnd(_ window: Window) -> Bool {
        var owed = false
        for line in window.sent where line == begin || line == end {
            owed = line == begin
        }
        return owed
    }
}
