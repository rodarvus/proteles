# Notifications — extensible macOS notifications

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

## Decisions for the user
1. **MVP rule set** — tells + mention enough to start? (Recommended.)
2. **Suppress-when-focused** default on? (Recommended — avoids banner spam while
   actively playing.)
3. **Sounds** — use the system default, or bundle a subtle custom sound?
4. Permission UX — request on first connect, or on first enabling in Preferences
   (recommended: when the user enables it, so it's intentional)?

## Effort
Medium. The matcher + rules + Preferences is the bulk; the UNUserNotifications
layer is small. No new dependencies.
