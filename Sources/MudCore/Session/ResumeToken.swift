import Foundation

/// A breadcrumb the app refreshes **while connected** so the next launch can
/// **resume the session** instead of cold-starting (#42, auto-update Phase 2
/// "client-side copyover").
///
/// Client-side copyover is *not* socket/stream preservation (impossible across a
/// process relaunch — see `docs/plans/AUTOUPDATE_AND_COPYOVER.md`); it's a fast,
/// framed reconnect. Rather than hook Sparkle's relaunch (an `@objc` delegate,
/// awkward under strict concurrency), the app writes this token whenever a
/// connection comes up and clears it on an explicit user disconnect. On launch a
/// *fresh* token means "we were mid-session and the process restarted" — whether
/// from a Sparkle update, a crash, or a quick relaunch — so we reopen the world,
/// restore scrollback, reconnect, and frame it ("Updated to vX" if the running
/// version is newer, else "Reconnecting…") instead of the alarming Disconnected
/// state.
public struct ResumeToken: Codable, Sendable, Equatable {
    /// The world that was active + connected when the token was (re)written.
    public let worldID: UUID
    /// The app version **that wrote the token** (i.e. the version running while
    /// connected). Compared to the running version on the next launch:
    /// `wasUpdated(runningVersion:)` is true when the running version is newer —
    /// meaning the relaunch was a Sparkle update (frame "Updated to vX"); equal
    /// means a quick restart or crash recovery (frame "Reconnecting…"). Either
    /// way we resume the session.
    public let appVersion: String
    /// When the token was written. ``isFresh(now:maxAge:)`` ignores a stale token
    /// so a launch long after the app last quit is treated as a cold start, not a
    /// surprise auto-reconnect.
    public let stamp: Date

    public init(worldID: UUID, appVersion: String, stamp: Date) {
        self.worldID = worldID
        self.appVersion = appVersion
        self.stamp = stamp
    }

    /// Honoured only if written recently (default 2 min). An update relaunch is
    /// near-immediate; a much older token means the app simply isn't being
    /// resumed (a later cold launch), so don't auto-reconnect.
    public func isFresh(now: Date, maxAge: TimeInterval = 120) -> Bool {
        let age = now.timeIntervalSince(stamp)
        return age >= 0 && age <= maxAge
    }

    /// True when `runningVersion` is newer than the version that wrote the token
    /// (numeric-aware compare, so "0.4.10" > "0.4.9") — i.e. an update landed.
    public func wasUpdated(runningVersion: String) -> Bool {
        runningVersion.compare(appVersion, options: .numeric) == .orderedDescending
    }
}

/// Reads/writes a single ``ResumeToken`` as JSON (a one-shot breadcrumb, not a
/// store of record). Consume-once: ``take()`` reads then deletes, so a resume
/// never fires twice.
public struct ResumeTokenStore: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Documents/Proteles/State/resume.json` (#43).
    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        try ProtelesPaths.resumeFile(fileManager: fileManager)
    }

    public func write(_ token: ResumeToken) throws {
        try JSONEncoder().encode(token).write(to: url, options: .atomic)
    }

    /// The current token without consuming it (`nil` if absent/unreadable).
    public func peek() -> ResumeToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResumeToken.self, from: data)
    }

    /// Read **and delete** the token (consume-once), so a resume can't re-fire on
    /// a later launch. Returns `nil` if there was none.
    public func take() -> ResumeToken? {
        let token = peek()
        clear()
        return token
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
