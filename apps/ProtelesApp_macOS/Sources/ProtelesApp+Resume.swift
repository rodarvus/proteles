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
                // written to the sidecar again (it's already there).
                //
                // Seed as ONE batch, not a per-line loop: the render view
                // attaches on its own Task and snapshots the store, so a
                // per-line `append` raced it — if the view attached mid-seed,
                // the remaining lines trickled in through the live event
                // stream, rendering one-by-one interleaved with the freshly
                // connecting session's output (regression 2026-06-13: removing
                // the slow SQLite open sped launch up enough to lose the race).
                // `appendBatch` appends in a single actor hop, so the backlog
                // renders in one snapshot/flush however the race lands.
                let tail = resuming ? await persistence.loadTail(limit: 400) : []
                if !tail.isEmpty {
                    // Trailing blank line = the divider before the fresh session.
                    await store.appendBatch(tail + [Line(id: LineID(0), text: "")])
                }
                await persistence.attach(to: store)
            }
        }

        // Chat window resume (#57): same dance — seed, then attach. Unlike
        // scrollback the Chat window has no divider concept; restored lines
        // keep their original timestamps, which the window already shows.
        // Seed as ONE batch (like scrollback's appendBatch) so the panel fills
        // in a single pass rather than line-by-line.
        if let chatPersistence, let chatStore {
            Task {
                let tail = await resuming ? ((try? chatPersistence.loadTail(limit: 500)) ?? []) : []
                let rows = tail.compactMap { row -> ChatLine? in
                    (try? row.toLine()).map {
                        ChatLine(
                            id: 0,
                            timestamp: row.timestamp,
                            channel: row.channel,
                            player: row.player,
                            line: $0
                        )
                    }
                }
                if !rows.isEmpty {
                    await chatStore.restoreBatch(rows)
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
