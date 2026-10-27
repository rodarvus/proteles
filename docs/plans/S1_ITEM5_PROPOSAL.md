# S1 step 5 — notification sounds through the cue pipeline

> **Status: implemented and live-checked (§9). Approved 2026-10-27 as
> proposed: Q1 yes, Q2 (a), Q3 (a).
> Q2 refined on approval:** the Mac stores no alert-sound choice by default
> (`com.apple.sound.beep.sound` is unset), and naming the default's file
> would be a guess. So Default plays the chosen alert file as a cue when
> one is set; otherwise macOS plays its alert sound itself
> (`AudioServicesPlayAlertSound`). Silent, `spcat notification 0` and the
> repeat rule still apply; a partial volume does not. Tracking: **#83**.
> Order of work: `IOS_PORT_PLAN.md` §4a S1 (v0.5), step 5.

## 1. The ratified scope, verbatim

From **#83**:

> - [ ] Notification-rule sounds unified onto the same pipeline (removing the
>       second, unrelated audio path)

From **D-127** (4):

> **Notification-rule sounds** route through the cue pipeline in their own
> category, which the soundpack's master mute does not silence, so a player
> with rule sounds and a muted soundpack keeps hearing them.

### 1.1 My reading (Q1 below)

- **The second audio path** is the notification banner's own sound: the app
  sets `content.sound` on the `UNNotificationRequest`, and macOS plays it
  with the banner (`NotificationController.post`). It knows nothing about
  the cue map, volume caps or playback discipline.
- "Removing" that path means **no banner carries a sound any more**. The
  sound becomes a cue, made by the cue map and played by the cue player.
- That has to cover **every** notification, not only the rules. Tells,
  mentions, group invites and a plugin's `Notify(…)` post banners with the
  default sound too. If only the rules moved, the second path would stay.
  This is Q1.

## 2. What happens today

**Where notifications come from** (`SessionController+Notifications.swift`):

| Source | Sound today |
|---|---|
| Rules: keyword, channel, low HP, quest ready | the rule's choice: Default, Silent, Glass, Ping, Submarine, Hero, Funk |
| Built-in tells and mentions | Default |
| Group invites | Default |
| A plugin's `Notify(…)` / `proteles.notify` | Default |

`Default` leaves the choice to macOS (`UNNotificationSound.default`). A
named choice asks for that system sound by name.

**What the recordings say** (October's 114 sessions, `NOTIF` lines): 760
banners posted: 638 quest ready, 78 tells, 23 low HP, 18 mentions, 3 group
invites. Your two rules (quest ready, HP below 25 %) are both on Default.
None were held back for focus, because "Also notify while Proteles is in
focus" is on.

**What silences the sound today:** a rule set to Silent; the master
notifications toggle; the focus policy (no banner, so no sound); macOS's
own Focus / Do Not Disturb and per-app notification settings. The
soundpack mute does not, because this path never touches the soundpack.

## 3. What changes

**MudCore**

- A new category, **`notification`**, and one fixed event in it,
  **`notification`**, whose payload names the file to play. This is the
  same arrangement as step 4's `trigger_sound`. Its volume is
  `min(notification, notification category, master)`, so `spcat
  notification 40` caps every notification sound.
- `ProtelesNotification` carries a **`cue: SoundCue?`** in place of
  `playSound`/`soundName`. The cue is computed in MudCore when the
  notification is published (after coalescing), so the volume caps apply.
  Silent means no cue.
- **The cue map makes it**, as for every other cue. The session emits the
  `notification` event to the native plugins, takes the resulting cue, and
  attaches it to the notification instead of playing it directly
  (§4, Q3).
- **The soundpack mute does not silence it** (D-127 (4)):
  - `Soundpack` plays a `notification` event while muted.
  - The registry delivers an *emitted* event to every enabled plugin. Its
    `wantsSemanticEvents` gate stays where it belongs, in front of
    *classification* (D-127 (1): a cost guard, not routing).
  - The session's mute gate on `.playSound` is never in the way, because
    this cue reaches the player with the notification, not through
    `.playSound`.
- **Which file each choice plays:**
  - Glass, Ping, Submarine, Hero and Funk name macOS's own sounds:
    `Glass.aiff` and so on. The macOS player resolves them in
    `/System/Library/Sounds/`, after the Sounds folder and the bundled
    defaults.
  - Default is Q2.

**App**

- `NotificationController.post` no longer sets `content.sound`. When it
  posts the banner, it hands the notification's cue to the cue player,
  which applies playback discipline as usual.
- The macOS player gains one resolution tier, `/System/Library/Sounds/`,
  for the named choices and for Default (per Q2).

## 4. Open questions

**Q1 — Does "notification-rule sounds" cover every notification sound?**
Recommended: **yes.** Tells, mentions, group invites and `Notify(…)` move
too, because the step's stated purpose is removing the second path, and
only that removes it. If you read it as rules only, the other four keep
the banner sound and the second path stays, for them.

**Q2 — What does Default sound like?** Today it is whatever macOS plays
for `UNNotificationSound.default`, which I can't inspect.
- **(a) Your macOS alert sound** (System Settings ▸ Sound ▸ Alert sound),
  resolved by the macOS player and played as a cue. **Recommended.** It is
  the closest stand-in I can name for today's sound, but you would need
  to confirm it by ear.
- **(b) A fixed sound**, for example `Glass.aiff`. Predictable, and the
  same on iOS later, but different from today.

**Q3 — When does the sound play?**
- **(a) Only when the banner posts.** The cue rides on the notification,
  and the app plays it at the moment it posts the banner. When it plays
  stays exactly as today, including the focus policy. Only how it plays
  changes: volume caps, discipline, and the soundpack mute not applying.
  **Recommended.**
- **(b) Whenever a notification is published**, even when focus holds the
  banner back. Simpler, since the session would play it directly. But a
  player with "notify while focused" off would start hearing sounds they
  don't hear today.

## 5. Options considered

- **A. A `notification` event through the cue map, the cue riding on the
  notification. Proposed.** One place makes cues; the mute exemption is
  stated where the mute is; when it plays doesn't change.
- **B. The app plays a sound itself** (`NSSound`) when it posts. That is
  still a second path outside the cue map: no category cap, no
  discipline. Rejected.
- **C. One event per rule** (the rules' existing `rule.<id>` events) as
  the cue key. That would give each rule its own volume, but the names are
  dynamic, outside the vocabulary, and unlisted by `spset`, which is the
  user-defined-event surface D-122 rules out. Rejected; the rule's own
  sound choice already distinguishes rules.

## 6. What does not change

- **Which notifications fire**, their titles and bodies, coalescing, the
  focus policy and the master toggle.
- **The rule editor:** the same seven sound choices. Choosing files from
  the Sounds folder belongs to the Settings step if anywhere.
- **The soundpack's own `tell` cue.** A tell still plays both `tell.wav`
  (when the soundpack is unmuted) and the tell banner's sound, as today.
  Folding those into one is a separate question.
- **Trigger sounds** (step 4) still follow the soundpack mute.

## 7. Impact

- **Do Not Disturb / Focus.** macOS will no longer silence these sounds,
  because Proteles plays them, not the banner. Under Do Not Disturb you
  would still hear a quest-ready sound. Proteles's own controls replace
  it: Silent on the rule, `spcat notification 0`, or the notifications
  toggle. **This is the main user-visible change**, and it can't be
  avoided if the sound leaves the banner. macOS's per-app "Play sound for
  notifications" setting stops applying for the same reason.
- **Discipline:** notification cues share one event, so two notifications
  inside 0.25 s play one sound. Both banners still show.
- **Volume:** notification sounds become subject to the master volume
  (`spvol`). Today they ignore it.
- **Hot path:** none. Notifications are rare (760 in a month), and each
  costs one actor hop to the engine to make its cue.
- **Files:** `NotificationMatcher.swift` (`ProtelesNotification`),
  `SessionController+Notifications.swift`, `NativePlugin.swift` (delivery
  of emitted events), `Soundpack.swift`, `SoundpackConfig.swift`,
  `SemanticEvent.swift` and the vocabulary, `NotificationController.swift`
  and `CuePlayerController.swift` (app), and tests.

## 8. Tests

- **Matcher:** a rule's sound choice becomes the right cue file; Silent
  gives no cue; tells, mentions and group invites carry the Default cue.
- **Session:** a published notification carries a cue at
  `min(notification, category, master)`, **including while the soundpack
  is muted**; `spcat notification 0` gives no cue; a coalesced duplicate
  carries nothing.
- **Registry:** an emitted event reaches a plugin whose
  `wantsSemanticEvents` is false; classification still doesn't run while
  nothing wants events.
- **Trigger sounds** still follow the mute (step 4's test stays green).

**Live check for you:** with the soundpack muted, wait for quest ready (or
let HP drop below 25 %). You should hear the notification's sound, and
`spcat notification 20` should make it quieter.

## 9. Implementation notes (2026-10-27)

- **Emitted events** go through `NativePluginRegistry.emit(_:)`, which
  reaches every enabled plugin. Classified events still go through the
  gated `onSemanticEvent(_:)`. Trigger sounds (step 4) now use `emit` too;
  their mute still applies, inside `Soundpack`.
- **`ProtelesNotification`** carries `sound` (the choice) and `cue`
  (attached at publish). `playSound`/`soundName` are gone, and so is
  `NotificationRule.Sound.systemName`, replaced by `cueFile`.
- **Publishing stays synchronous** (`notifyForOutput` is on the per-line
  path). The cue is fetched from the engine in a task, so a sounded
  notification may be yielded after a silent one published just after it.
- **`SoundpackConfig.fileCue(for:file:)`** replaces step 4's
  `triggerCue(file:)` and serves both file-naming events.
- **The macOS player:**
  - `/System/Library/Sounds/` is a new resolution tier, after the bundled
    defaults;
  - `SoundCue.systemAlertFile` plays the file stored under
    `com.apple.sound.beep.sound` when there is one, else
    `AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)`,
    which holds a governor slot for 1 s;
  - the banner and `willPresent` carry no sound.
- **Tests:** `NotificationSoundTests` (6). Removing the mute exemption
  fails three of them. Matcher tests updated for the new fields.
- **Live check (2026-10-27):** with the soundpack muted, notification
  sounds played. Default plays the macOS alert sound, a short beep. That
  is audibly different from the banner's old notification sound, and the
  user accepted it. A rule set to Glass played Glass, and
  `spcat notification` capped it.
