import Foundation

/// A breadcrumb the app writes just before a Sparkle-initiated relaunch so the
/// next launch can **resume the session** instead of cold-starting (#42, auto-
/// update Phase 2 "client-side copyover").
///
/// Client-side copyover is *not* socket/stream preservation (impossible across a
/// process relaunch — see `docs/plans/AUTOUPDATE_AND_COPYOVER.md`); it's a fast,
/// framed reconnect. This token is what turns "the app happened to reconnect on
/// launch" into "the app deliberately put you back where you were": it names the
/// world to reopen + connect, and marks the launch as post-update so the UI can
/// restore scrollback and show "reconnecting after update…" rather than the
/// alarming Disconnected state.
public struct ResumeToken: Codable, Sendable, Equatable {
    /// Why the app is relaunching. Only `update` for now; leaves room for a
    /// future user-initiated "restart & resume".
    public enum Reason: String, Codable, Sendable {
        case update
    }

    /// The world that was active (and connected) at relaunch.
    public let worldID: UUID
    public let reason: Reason
    public let fromVersion: String?
    public let toVersion: String?
    /// When the token was written. Used by ``isFresh(now:maxAge:)`` to ignore a
    /// stale token (e.g. a relaunch that never completed, then a cold launch
    /// hours later — we don't want to silently auto-connect then).
    public let stamp: Date

    public init(
        worldID: UUID,
        reason: Reason = .update,
        fromVersion: String? = nil,
        toVersion: String? = nil,
        stamp: Date
    ) {
        self.worldID = worldID
        self.reason = reason
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.stamp = stamp
    }

    /// A token is honoured only if written recently (default 2 min): an update
    /// relaunch is near-immediate, so a much older token means the relaunch
    /// didn't follow and this is really a cold start — don't auto-resume.
    public func isFresh(now: Date, maxAge: TimeInterval = 120) -> Bool {
        let age = now.timeIntervalSince(stamp)
        return age >= 0 && age <= maxAge
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

    /// `~/Library/Application Support/com.proteles.ProtelesApp/resume.json`.
    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = support.appendingPathComponent("com.proteles.ProtelesApp", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("resume.json")
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
