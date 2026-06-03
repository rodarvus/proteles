# Proteles v0.4.5 — Test Plan

Live-play test plan for the features shipped in **v0.4.5** (first notarized
build): the as-you-type ghost hint (#13), command-button bar (#15), group-panel
refinements (#17), opt-in crash diagnostics (#24), and notifications (#14).

**Build under test:** `~/Applications/Proteles.app` (v0.4.5, notarized).
Recordings auto-write to
`~/Library/Application Support/com.proteles.ProtelesApp/recordings/` — when
something misbehaves, grab the `.log` transcript for the bug report (fastest way
to reproduce). File each bug with: (a) what you did, (b) what you expected,
(c) what happened, (d) the transcript timestamp.

---

## #13 — As-you-type ghost hint

A grey inline suggestion after your caret, completing the current word from
on-screen targets/exits/group/recent output. Toggle:
**Preferences ▸ "Suggest completions as you type"** (`inputGhostHint`, default on).

| # | Steps | Expected |
|---|---|---|
| 13.1 | Connect; in a room with a visible mob, type the start of its name | Grey suffix ghost appears after the caret |
| 13.2 | With the ghost showing, press **→ (right arrow)** | Ghost accepted in the match's real casing; caret at end |
| 13.3 | Type a word with a ghost, press **Esc** | Ghost disappears; field text unchanged |
| 13.4 | Ghost showing, press **Tab** | Tab-cycle completion still works (ghost is the first Tab candidate) |
| 13.5 | Ghost showing, move caret into the middle of the line (←), then → | No spurious accept — → is a normal caret move when not at end-of-line (ghost hides) |
| 13.6 | Preferences → toggle the setting off; type | No ghost ever appears |
| 13.7 | Type until the word fills the field to the right edge | Ghost hides gracefully (no overflow/clipping) |
| 13.8 | Resize the input field / change theme/font while a ghost shows | Ghost stays aligned to the caret |

Watch for: ghost mis-positioned after font/theme/resize; ghost surviving a caret
move; → accepting when it shouldn't; casing not matching the real target.

---

## #15 — Command-button bar

Grouped clickable command/toggle buttons. Show: **Panels ▸ Commands**. Author:
**Scripts ▸ Buttons**. Scriptable via Lua `Button.*`.

| # | Steps | Expected |
|---|---|---|
| 15.1 | Scripts ▸ Buttons → add a group, add a command button | Button appears in the Commands panel under that group's tab |
| 15.2 | Click the button | Command runs through the normal pipeline |
| 15.3 | Add a toggle button (on/off cmds) | Click alternates; on draws solid, off draws tinted-light |
| 15.4 | Dock top/bottom vs left/right, and tear off to a floating window | Layout flows to fill; orientation follows placement |
| 15.5 | Set tint + SF Symbol icon + hotkey-echo | All three render on the cell |
| 15.6 | Create several groups | Group tabs page between them |
| 15.7 | Quit & relaunch | Buttons persist per-world |
| 15.8 | Lua: `Button.add("Combat","Flee","flee")` | Button appears live |
| 15.9 | `Button.toggle("Combat","Wimpy","wimpy 20","wimpy 0")` then `Button.state("Wimpy", true)` | Toggle created; state lights it on |
| 15.10 | `Button.remove("Flee")` | Button disappears |

Known limitations (not bugs): toggle state is transient (not persisted);
reorder-by-drag is deferred (editor adds/deletes only).

---

## #17 — Group-panel refinements

The Character panel's group section: leader/align/HP#/quest column + filter +
sort. Prefs persist via `group.roomOnly` / `group.sort`.

| # | Steps | Expected |
|---|---|---|
| 17.1 | Join/form a group; open the Character panel | Each row shows name + HP/MP bars |
| 17.2 | Identify the leader | Crown badge on the leader |
| 17.3 | Members of differing alignment | Alignment dot reflects good/neutral/evil |
| 17.4 | Read a row | HP numbers shown (not just the bar) |
| 17.5 | Members on quest | Quest-timer column (`qt`/`qs`) shows the tag |
| 17.6 | Ellipsis (…) menu → Show this room only | Filters to room-only; survives relaunch |
| 17.7 | Ellipsis menu → Sort: Standard / Most hurt / Quest first | Reorders; choice persists |
| 17.8 | Damage a member, re-sort "Most hurt" | Most-hurt member rises to top |

Watch for: quest column empty when it shouldn't be (verify against a transcript's
group GMCP — `v.info.qt`/`v.info.qs`); unstable sort; crown on wrong member.

---

## #24 — Opt-in crash diagnostics

MetricKit crash/hang capture, off by default, on-device only.
**Preferences ▸ Diagnostics** (ladybug tab); `diagnostics.enabled`.

| # | Steps | Expected |
|---|---|---|
| 24.1 | Open Preferences ▸ Diagnostics | Pane loads; toggle off by default; empty list |
| 24.2 | Toggle on | No crash; MXMetricManager subscription registered |
| 24.3 | (If a prior crash/hang exists) | Reports list populates newest-first, ≤20 |
| 24.4 | Select a report → Copy summary | Plain-text summary on the clipboard |
| 24.5 | If a report correlates to a session | A correlated-recording affordance appears |
| 24.6 | Delete one / Delete all | Removed from list + from `…/diagnostics/` |
| 24.7 | Toggle off | Capture stops |

Note: MetricKit payloads are delivered by the OS at next launch (often ~24h
after an event), so an empty list is expected, not a bug.

---

## #14 — Notifications

Native macOS notifications. **Preferences ▸ Notifications**. Suppressed while the
app is focused by default — test with Proteles backgrounded.

Template tokens: channel rule → `{channel}` `{player}` `{message}` `{line}`;
keyword/regex → `{line}` `{match}` `{capture}`; low-HP → `{percent}` `{threshold}`.

| # | Steps | Expected |
|---|---|---|
| 14.1 | Grant permission (System Settings ▸ Notifications ▸ Proteles) | Required for the rest |
| 14.2 | Default tell / name-mention | Notification when backgrounded |
| 14.3 | Keyword rule | Fires; `{line}`/`{match}` resolve |
| 14.4 | Regex rule with a capture group | `{capture}` populates |
| 14.5 | Channel rule for one channel | Only that channel notifies; `{player}`/`{message}` resolve |
| 14.6 | Low-HP rule; drop below, recover, drop again | Edge-triggered (fires on each crossing in, not repeatedly while low) |
| 14.7 | Quest-ready when the quest timer is up | Fires off `comm.quest` GMCP (with or without S&D) |
| 14.8 | Per-rule sound | Sound plays with the notification |
| 14.9 | Trigger a rule rapidly many times | Coalescer collapses the burst |
| 14.10 | App focused, trigger a rule | Suppressed (default) |
| 14.11 | `Notify("title","body")` from an alias/trigger | Scripted notification appears |

Watch for: low-HP firing every tick instead of on the edge; quest-ready never
firing (check a transcript for the `comm.quest` shape); coalescer dropping
distinct notifications; tokens left literal instead of substituted.

---

## Results log

### v0.4.5 round 1 (2026-06-03)

- **#13** — works as expected. 13.1/13.5 confirmed (13.5: ghost hides on caret
  move into the middle — intended). Follow-ups: completion-source quality
  (verb/command vocabulary, per-command argument completions) — see GH issues.
- **#15** — BUG: "add group" in Scripts ▸ Buttons does nothing (blocks all
  further button testing).
- **#24** — opt-in toggle works; BUG: opening Diagnostics shrinks the Settings
  window and it can't be resized again. Also requested: make Settings (and all
  dialogs) resizable; a way to force a synthetic crash report for testing.
- **#14 / #17** — feedback pending (separate round).
