# Logging — per-session HTML/text logs + rotation + UI

> **Status: shipped (feature-complete for 1.0; D-49 + D-68). Historical design
> doc — kept for the rationale and trade-offs.** `SessionLogger` (text + HTML),
> per-connect files, the Preferences ▸ Logging tab, rotation/retention, and the
> per-world override all landed. See `../DECISIONS.md` (D-49, D-68).

> Plan deliverable (no code). User-facing session logging, distinct from the two
> things we already write per connect: the binary replay (`.jsonl`, raw wire
> bytes) and the debug transcript (`.log`, local events for *our* debugging).
> Logging is for the **player**: a readable record of what happened, with colour.

## What existed vs what was missing (at planning time)
- ✅ `SessionRecorder` → `.jsonl` (replay; not human-friendly).
- ✅ `SessionTranscript` → `.log` (debug: RECV/SEND/INPUT/GMCP, ms stamps).
- 🔴 (then) **No user log** — no "save my session as readable text/HTML", no UI,
  no rotation, no per-world control. **Now shipped** (`SessionLogger`, D-49/D-68).

We already have the encoders to make this cheap: `HTMLEncoder` (styled `<pre>`
+ `<span>` colour) and the plain-text path both exist (used by Copy-as-HTML /
Copy-as-text). Logging is largely "stream finalized lines to a file using these
encoders," which keeps it almost free.

## Proposed design

- **MudCore `SessionLogger` (actor)** — subscribes to the `ScrollbackStore`
  line stream (it already publishes finalized lines) and appends each to an
  open log file. Format is a setting:
  - **Plain text**: ANSI stripped (readable) — the default.
  - **HTML**: reuse `HTMLEncoder` per line into a styled `<pre>` document with a
    header/footer (dark bg, monospace) so colours survive — like Mudlet's HTML log.
  - (Optional later) **ANSI text**: keep raw SGR for re-coloring in another tool.
- **What's logged**: finalized output lines + (optionally) the user's input
  echo. Gagged lines: follow the visible output by default (don't log what you
  didn't see), with a "log everything incl. gagged" power option.
- **File naming + location**: `~/Library/Application Support/com.proteles
  .ProtelesApp/logs/<World>/<Character>-YYYY-MM-DD-HHMMSS.{txt,html}`. Per-world
  subfolders so logs are easy to find.
- **Rotation**: by **size** (roll to `-N` when a file exceeds N MB) and/or by
  **session** (one file per connect — the natural unit). Plus a retention cap
  (keep the most recent K files / M days; prune older). All configurable.
- **Lifecycle**: open on connect (if logging enabled for that world), flush
  periodically + on disconnect/quit, close cleanly. Reconnect appends to the
  same session file (or starts a new one — a setting).

## Architecture fit
Mirrors the recorder: an actor fed by the scrollback stream, owned by the
`SessionController`, toggled by a preference. The line→text/HTML conversion is
pure (reuses existing encoders), so it's unit-testable (feed lines, assert file
contents). No UI coupling in MudCore.

## UI (Preferences ▸ Logging tab + menu)
- Toggle: **Enable session logging** (global default) + per-world override in
  the world editor.
- Format: Text / HTML.
- "Log my input too" toggle.
- Rotation: size cap (MB), retention (keep last N sessions / days).
- A **"Reveal Logs in Finder"** button (opens the logs folder).
- A **File ▸ "Open Log Folder"** menu item; optionally a live "Logging ●"
  indicator in the status/gauge bar while recording.

## Phases
1. `SessionLogger` (text + HTML) + per-connect file + Preferences toggle +
   "Reveal in Finder". (MVP — covers 90% of need.)
2. Rotation (size) + retention pruning + per-world override.
3. Power options: log gagged lines, ANSI format, append-on-reconnect.

## Decisions for the user (resolved as shipped)
1. **Default format** — plain text (recommended) or HTML? → shipped with both.
2. **Default on or off?** Off by default (privacy; logs can contain tells);
   easy to enable per world. → as recommended.
3. **Log input?** Default off (avoids logging passwords/whispers) with an opt-in.
   → as recommended; autologin uses `sendLine` and echo-off prompts aren't echoed,
   so passwords never reach the user log (verified, D-68).
4. **Rotation policy** — per-session files (recommended, simplest) vs size-rolled
   continuous logs? → per-session files, plus a retention cap (keep newest N,
   default 30; `LogRetention.filesToPrune`, D-68).

## Effort (as built)
Low–medium, as estimated. The encoders + scrollback stream already existed; the
work was an actor + file I/O + a Preferences tab. Lowest-risk of the Phase-7
features.
