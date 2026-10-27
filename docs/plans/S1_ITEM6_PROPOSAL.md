# S1 step 6 — Settings ▸ Audio: preview and per-category controls

> **Status: implemented and live-checked (§8). Approved 2026-10-27 as
> proposed: Q1 (a) a per-category event list with preview, Q2 (a) no live
> refresh.** Tracking: **#83**.
> Order of work: `IOS_PORT_PLAN.md` §4a S1 (v0.5), step 6, the last.

## 1. The ratified scope, verbatim

From **#83**:

> - [ ] Settings ▸ Audio: preview + per-category controls
> - [ ] `spset` et al. retained as the console surface over the same store

From **D-127** (1) and (2):

> only the cue map, mixer, playback discipline and Audio settings are
> sound-side.

> **Category volume is a cap**, like the reference's master: effective =
> min(event, category, master)

From **D-122**, the standing test:

> V1 is wholesale: users do not enable/disable event categories, there are
> no user-defined events or lenses … This is the standing test for any
> design that would add configuration surface

And the plan's S1 exit: *the user (sighted, macOS) declares sound a feature
they actually use.*

### 1.1 My reading

- **Per-category controls** means one **volume cap per category**, the
  `spcat` values, in the window. That is the only per-category setting the
  cue map has. A cap at 0 silences a category, but the window shows no
  separate on/off switch for each one (D-122).
- **Preview** means hearing a sound from the window, played exactly as it
  would play in-game: the same file resolution and the same effective
  volume. The question is what you preview (Q1).
- **`spset` et al. retained** is already true. The window and the console
  edit the same `soundpack.json` and reload the same plugin. This step
  keeps it true and ticks that box (§6).

## 2. What exists

**Settings ▸ Audio ▸ Sounds** (`AudioSettingsView.swift`, app target)
today has:

- "Play event sounds" (the soundpack mute);
- the master volume;
- "Use system alert when a sound file is missing";
- "Open Sounds Folder".

Its doc comment says per-event tuning stays on `spset`, because "69 events
don't belong in a window". Edits write the JSON and reload the plugin
(`reloadNativePluginConfig`). A slider saves when you release it.

**The categories and their events** (`SemanticEventVocabulary`, 77 names):

| Category | Events | With a sound by default |
|---|---|---|
| communication | 41 | 41 |
| world | 11 | 11 |
| progression | 6 | 5 (not `skill_gain`) |
| affect | 5 | 0 (the spellup tags) |
| combat | 4 | 4 |
| system | 4 | 4 |
| inventory | 2 | 2 |
| group | 2 | 2 |
| custom | 1 (`trigger_sound`) | — (each trigger names its file) |
| notification | 1 (`notification`) | — (each rule names its sound) |

Your own `soundpack.json` has no category caps and no per-event overrides.

## 3. What changes

**A new "Categories" section** in Settings ▸ Audio, under Sounds, with
one row per category in the vocabulary's order:

- **A name**, in words: Channels and tells, World and quests, Combat,
  Progression, Spells and skills, Items, Group, Server messages, Your
  triggers, Notifications.
- **A volume slider, 0–100**: the category cap. It saves when you release
  it, like the master. `spcat` sets the same value.
- **A preview button** (▶) that plays a sample for the category (Q1).
- For **Notifications**, a caption: "Plays even when event sounds are off;
  choose sounds per rule in Notifications." For **Your triggers**:
  "Choose sounds per trigger in Scripts."

**Preview mechanics**

- The window gets its own `CuePlayerController`. It resolves files exactly
  as the session's player does (Sounds folder, bundled defaults, macOS
  sounds, the system alert), and has its own playback discipline. Preview
  never goes through the session, so it plays **even while event sounds
  are off**: you asked to hear it.
- The cue comes from the cue map (`SoundpackConfig.cue(for:)`), so it
  plays at the **effective** volume: the event, its category's cap
  (including the value you're dragging) and the master. A category at 0
  previews silence, and its button says so.
- An event with no file (the spellup tags, `skill_gain`) has nothing to
  preview. Its button is disabled, with "No sound set — `spset <event> wav
  <file>`".

**Where the code lives**

- The categories section is a view in **MudUI** (`SoundCategoriesSection`).
  It edits a `SoundpackConfig` binding and takes a `preview: (SoundCue) ->
  Void`, so the iOS Settings phase can reuse it. The macOS app passes its
  player. Display names live next to it.
- `AudioSettingsView` (app) hosts it and keeps its save-on-release and
  reload pattern. Its doc comment and the Sounds caption change: the mute
  no longer silences notification sounds, and categories are in the window
  now.

## 4. Open questions

**Q1 — What does preview play?**

- **(a) A list of each category's events, each with ▶. Recommended.** A
  disclosure under each category row lists its events by name, with the
  file each would play, and a ▶. You can hear what `bonus_item` or `gtell`
  sounds like before deciding to cap a category, which is what preview is
  for. It is a read-only list: per-event volume, pan and files stay on
  `spset`, so no per-event controls appear (D-122).
- **(b) One sample per category.** One ▶ per row plays a fixed
  representative (communication → `tell`, world → `quest_ready` …). Less
  to show, but you hear one of 41 channel sounds and have to guess the
  rest.

**Q2 — Refresh when the console changes things.** If the window is open
and you run `spcat world 30` in the game, the window shows the old value
until you reopen the tab, as the master volume does today.

- **(a) Leave it.** Same as today's controls. **Recommended**: the window
  and the console are rarely used at the same moment, and a live sync
  means watching the file or adding a session stream for one window.
- **(b) Re-read on window focus.** Cheap, but it touches the existing
  controls too.

## 5. Options considered

- **A. Category caps plus preview, in a MudUI section. Proposed.**
- **B. Per-event controls in the window** (volume, pan and files for 77
  events). That is the configuration surface D-122 says V1 doesn't have,
  and the current doc comment already rejects it. Rejected; `spset` stays
  the per-event tool.
- **C. Preview through the session** (`spfire`). It would follow the
  mute, so with event sounds off you couldn't preview anything, and it
  goes through the session's governor. Rejected.
- **D. Keep the section in the app target.** Simpler today, but the iOS
  Settings phase would rewrite it. Rejected, since moving it later costs
  more than placing it now.

## 6. What does not change

- **The cue map, the store and the console.** `spset`, `spcat`, `spvol`,
  `sptog` and `spmute` edit the same `soundpack.json`; the window adds no
  new setting. On commit, #83's last box ("`spset` et al. retained…") is
  ticked with this step, since nothing removes or forks the console path.
- **The master controls, the fallback toggle, the Sounds folder button,
  the Speech section.**
- **Rules' and triggers' own sound pickers.**

## 7. Impact

- **Behaviour:** none until you move a slider. A category slider writes
  exactly what `spcat` writes.
- **Performance:** none on any hot path. The window is a settings form;
  preview plays one file on a click.
- **Files:** a new `Sources/MudUI/Settings/SoundCategoriesSection.swift`
  (or under `MudUI/Audio/`), `AudioSettingsView.swift`, and tests.
- **Tests:**
  - the section's model logic: the category rows in order, each
    category's events, which have a file, and what preview would play
    (`cue(for:)` at the effective volume, nil at a cap of 0);
  - a category cap written from the window reads back through `spcat`.

  The SwiftUI view itself isn't unit-tested, as with the other settings
  views.

**Live check for you:** open Settings ▸ Audio. Preview a few events in a
category, drag that category's slider down, preview again (quieter), set
it to 0 (silent), and check `spcat` shows the same value.

## 8. Implementation notes (2026-10-27)

- **Files as built:**
  - `Sources/MudUI/Audio/SoundCategoriesSection.swift`: the section, plus
    the pure `SoundEventPreview` rows and `SoundCategoryText`;
  - `SemanticEventVocabulary.events(in:)`;
  - `AudioSettingsView.swift` hosts the section with its own
    `CuePlayerController` for previews. Its doc comment and the Sounds
    caption are updated.
- **Triggers and Notifications** show their caption in place of an event
  list; each event there names its own file.
- **Tests:**
  - `SoundCategoriesSectionTests` (MudUITests, 5): rows at the effective
    volume, a cap of 0, an event with no file, a `spset` override, the
    category text;
  - `SoundCategorySettingsTests` (MudCoreTests, 2): `events(in:)`
    partitions the vocabulary, and a cap the window saves is what the
    plugin plays under and what `spcat` lists.
- **Live check (2026-10-27):** the section, the event previews, the
  category caps (quieter, then silent at 0), `spcat` agreeing with the
  window, and preview with event sounds off all worked as expected.
