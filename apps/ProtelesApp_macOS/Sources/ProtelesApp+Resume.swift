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
        store: ScrollbackStore,
        chatPersistence: ChatPersistence? = nil,
        chatStore: ChatStore? = nil
    ) -> (store: ResumeTokenStore?, token: ResumeToken?) {
        let resumeStore = (try? ResumeTokenStore.defaultURL()).map(ResumeTokenStore.init(url:))
        let token = resumeStore?.take().flatMap { $0.isFresh(now: Date()) ? $0 : nil }
        let resuming = token != nil

        if let persistence {
            Task {
                // Seed the restored tail BEFORE attaching persistence so it isn't
                // written to the DB again (it's already there).
                let tail = await resuming ? ((try? persistence.loadTail(limit: 400)) ?? []) : []
                for line in tail {
                    await store.append(text: line.text, runs: line.runs)
                }
                if !tail.isEmpty {
                    await store.append(text: "") // blank divider before the fresh session
                }
                await persistence.attach(to: store)
            }
        }

        // Chat window resume (#57): same dance — seed, then attach. Unlike
        // scrollback the Chat window has no divider concept; restored lines
        // keep their original timestamps, which the window already shows.
        if let chatPersistence, let chatStore {
            Task {
                let tail = await resuming ? ((try? chatPersistence.loadTail(limit: 500)) ?? []) : []
                for row in tail {
                    guard let line = try? row.toLine() else { continue }
                    await chatStore.restore(
                        timestamp: row.timestamp,
                        channel: row.channel,
                        player: row.player,
                        line: line
                    )
                }
                await chatPersistence.attach(to: chatStore)
            }
        }
        return (resumeStore, token)
    }

    /// Drop the resume breadcrumb when the user **intentionally** ends the
    /// session — a `quit` command or an explicit disconnect — but not on a drop
    /// or an app / Sparkle-update shutdown (those leave the session's clean-end
    /// flags false), so update-resume keeps working (#42). Static so `init` can
    /// call it without the escaping `Task` capturing `self`.
    static func wireResumeClear(session: SessionController, store: ResumeTokenStore?) {
        Task { await session.setCleanSessionEndHandler { store?.clear() } }
    }
}
