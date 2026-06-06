import Foundation
import MudCore

/// Session-resume launch helper (#42). Split out of `ProtelesApp.swift` to keep
/// it under the size budget.
extension ProtelesApp {
    /// Consume the last-connected resume breadcrumb and, when it's fresh (the
    /// process restarted mid-session — Sparkle update, crash, or quick relaunch),
    /// seed the recent scrollback into `store` **before** persistence attaches so
    /// the restored history isn't written to the DB a second time. Returns the
    /// breadcrumb store (kept, to refresh on connect / clear on disconnect) and
    /// the fresh token (nil for a normal cold start). `take()` is one-shot so a
    /// resume can't re-fire on a later launch.
    static func resumeOnLaunch(
        persistence: ScrollbackPersistence?,
        store: ScrollbackStore
    ) -> (store: ResumeTokenStore?, token: ResumeToken?) {
        let resumeStore = (try? ResumeTokenStore.defaultURL()).map(ResumeTokenStore.init(url:))
        let token = resumeStore?.take().flatMap { $0.isFresh(now: Date()) ? $0 : nil }

        guard let persistence else { return (resumeStore, token) }
        let resuming = token != nil
        Task {
            if resuming,
               let tail = try? await persistence.loadTail(limit: 400), !tail.isEmpty
            {
                for line in tail {
                    await store.append(text: line.text, runs: line.runs)
                }
                await store.append(text: "") // blank divider before the fresh session
            }
            await persistence.attach(to: store)
        }
        return (resumeStore, token)
    }
}
