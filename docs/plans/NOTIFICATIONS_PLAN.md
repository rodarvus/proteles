# Notifications — extensible macOS notifications

> **Status: shipped (feature-complete for 1.0). Historical design doc — kept for
> the rationale and trade-offs.** Phase-1 (tells/mention + permission flow) landed
> as D-49; phase-2 (`proteles.notify`, custom keyword + per-channel rules) closed
> GitHub #14. `NotificationRule`/`NotificationMatcher`/`NotificationCoalescer` and
> the Preferences ▸ Notifications UI all exist. See `../DECISIONS.md` (D-49).

> Plan deliverable (no code). Native macOS notifications on tells / mentions /
> named events, **extensible** so scripts and plugins can fire custom
> notifications. Goal: know when something needs you while the window is in the
> background (a tell, your name on a channel, a quest popping, low HP, etc.).

## Architecture (pure rules + thin platform layer)

- **MudCore `NotificationRule` (Codable, per-world, unit-tested)** — a value
  type: `{ trigger, title template, body template, sound, enabled }`. Triggers:
  - `.tell` — incoming tells (`comm.channel` chan == "tell"/whisper).
  - `.mention` — your character name appears in a channel line / output.
  - `.channel(name)` — any line on a named channel.
  - `.pattern(regex)` — a user keyword/regex on output.
  - `.gmcpEvent(path, condition)` — e.g. `char.vitals.hp` below a threshold,
    `comm.quest` action == "ready".
- **MudCore `NotificationMatcher` (pure)** — given a `Line` / `ChatLine` /
  GMCP update + the rule set + **whether the app is frontmost**, returns the
  `Notification`s to post. Pure → fully testable (no UNUserNotifications).
- **Effect + host call**: `.notify(title, body, sound)` effect + `proteles
  .notify(title, body[, opts])` so **scripts/plugins fire custom notifications**
  — this is the extensibility hook (the MUSHclient corpus analog is plugins
  calling a notify function). The shim exposes it; native plugins emit the effect.
- **App `NotificationController` (macOS, UserNotifications)** — requests
  authorization once, posts `UNNotificationRequest`s, coalesces duplicates,
  handles the click (bring Proteles to front + focus the relevant panel, e.g.
  Channels for a tell). Modern `UNUserNotificationCenter` (not the deprecated
  `NSUserNotification`).

This keeps "should we notify?" pure/testable and isolates the OS API.

## Behaviour decisions baked into the matcher
- **Suppress-when-focused** (default on): don't notify for things you're already
  looking at; do notify when Proteles is in the background. Configurable per rule
  ("always notify" for critical ones like low HP).
- **Rate-limit / coalesce**: avoid a burst (e.g. a busy channel) becoming 30
  banners — collapse repeats within a short window.
- **Quiet during combat?** optional, for the spammy case.

## Built-in default rules (created on first run, editable)
1. **Tells** — title "Tell from {player}", body the message, sound on, notify
   when backgrounded. (The headline use case.)
2. **Name mention** — your character name on any channel.
3. **Quest ready** (`comm.quest` action) — optional, off by default.
Everything else (keyword rules, HP thresholds) the user adds.

## Extensibility (the explicit ask)
- `proteles.notify("title", "body")` in user scripts and the mush shim → fires a
  notification. So any plugin can raise one (e.g. S&D "campaign complete", a
  custom spellup-down alert). Documented as a first-class scripting primitive.
- Native plugins emit `.notify` directly.

## UI (Preferences ▸ Notifications)
- Master enable + "request permission" flow (first time).
- A list of rules (built-ins + user) with enable toggles + edit (trigger,
  title/body template with `{player}`/`{channel}`/`{capture}` tokens, sound,
  always-vs-when-backgrounded).
- "Suppress when Proteles is focused" global default.
- Test button (fire a sample notification to confirm permission/sound).

## Phases
1. `NotificationRule`/`NotificationMatcher` + `NotificationController` +
   the built-in **tells** + **mention** rules + Preferences enable + permission
   flow. (MVP — the 90% case.)
2. `proteles.notify` host call (script/plugin extensibility) + custom keyword
   rules + click-to-focus-panel.
3. GMCP-threshold rules (low HP, quest ready) + coalescing/rate-limit polish.

## Decisions for the user (resolved as shipped)
1. **MVP rule set** — tells + mention enough to start? → yes, shipped as the
   phase-1 built-ins.
2. **Suppress-when-focused** default on? → yes (with a delivery opt-out toggle).
3. **Sounds** — use the system default, or bundle a subtle custom sound?
4. Permission UX — request on first connect, or on first enabling in Preferences?
   → request when the user enables it, so it's intentional.

## Effort (as built)
Medium, as estimated. The matcher + rules + Preferences was the bulk; the
UNUserNotifications layer was small. No new dependencies.

---

## Phase-2 build decisions (resolved — shipped as GitHub #14)

Phase-1 shipped (D-49) + the in-focus toggle (delivery opt-out of
suppress-when-focused). Phase-2 = `proteles.notify` + custom keyword rules +
per-channel, full set. The decisions below were resolved as recommended and
shipped (#14):

1. **Persistence — recommend GLOBAL (not per-world).** The plan said per-world,
   but the shipped phase-1 prefs (enabled/tells/mention/in-focus) are global
   `@AppStorage`. Keep custom rules global too (a `Codable [NotificationRule]`
   in UserDefaults pushed to the session matcher) for consistency + no new
   per-world store. Easy to migrate to per-world later if wanted.
2. **Per-channel meaning — confirm.** Two readings: (a) **`.channel(name)`
   rules** = "notify on any line on channel X" (the plan's model), or (b) a
   **deny-list** that mutes spammy channels from the tells/mention alerts.
   Recommend (a) `.channel(name)` rules (composable with the rule model) **plus**
   a small per-rule "only on channel(s)" filter so a keyword rule can be scoped.
3. **Custom-keyword scope — recommend ALL output.** `.keyword(regex)` matches
   any incoming line (the powerful case: alert on a mob/word anywhere), not just
   chat. `proteles.notify` covers the scripter path; the keyword list is the
   non-scripter front-end.
4. **Lean rule model for v1** — `NotificationRule { id, label?, trigger
   (.keyword(TriggerPattern) | .channel(String)), enabled }`. Defer the plan's
   title/body templates + tokens + per-rule sound to phase-3 polish.

Build order once approved: `proteles.notify` host call (`.notify` effect + Lua
binding, gated by master-enable) → `NotificationMatcher` keyword/channel rules
(pure + tested, reusing `PatternMatcher`) → global persistence + push wiring →
Preferences ▸ Notifications rule-list UI.
