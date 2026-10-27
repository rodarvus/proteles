# S1 step 4 — the trigger `sound` action

> **Status: approved 2026-10-27 as proposed, with Q1 (a): the soundpack's
> mute silences trigger sounds too. Implemented and live-checked (§9).**
> Tracking: **#83**.
> Order of work: `IOS_PORT_PLAN.md` §4a S1 (v0.5), step 4.

## 1. The ratified scope, verbatim

From **#83**:

> - [ ] A `sound` action on GUI triggers that **emits a named event** into the
>       pipeline — never a raw play-file call

From **D-127** (3):

> **A trigger's `sound` action** names a vocabulary event, or plays an
> arbitrary file as one fixed first-party event in a fixed category —
> accepted as within D-122 (no user-defined events or categories).

And the plan's S1 exit criterion:

> a GUI trigger can play a sound with category volume applied.

### 1.1 My reading

- A trigger gets an optional **sound**. It is one of two kinds:
  - **an event**: one of the 75 vocabulary names (`tell`, `level_up`,
    `affect_on` …), which plays whatever that event's cue is;
  - **a file**, which plays as one fixed event, `trigger_sound`, in one
    fixed category.
- When the trigger fires, it **emits a `SemanticEvent`** through the same
  fan-out as every other event. The cue map turns it into a cue, so the
  volume caps, variants, playback discipline and mute all apply unchanged.
  Nothing in the trigger path plays a file.
- "GUI triggers" means the triggers in the Scripts window: the ones a
  player makes, plus the ones imported from a MUSHclient world file, which
  land in the same list.

## 2. What MUSHclient does, and what real data uses

**The reference** (`ProcessPreviousLine.cpp`, `xml_load_world.cpp`):

- A trigger has a `sound` attribute (a file path) and a `sound_if_inactive`
  flag (play only when the window is not focused).
- The sound plays when the trigger matches, **even if the trigger hides the
  line** (`omit_from_output`), behind a world-wide "enable trigger sounds"
  option.
- It plays through `PlaySoundFile`, not the soundpack's five buffers, and
  has no volume of its own. `"(No sound)"` means none.

**Real data:**

- The live world file (`Aardwolf.mcl`) has no trigger with a sound.
- No installed plugin uses one.
- The only uses found anywhere are six triggers in the Light PK-alert
  plugins, all `sound="C:\Windows\Media\Cityscape\Windows Error.wav"`: an
  absolute Windows path that can't exist on a Mac.

So the feature is new to Proteles rather than ported, and compatibility
matters only at import.

## 3. What changes

**MudCore: the trigger**

- New `TriggerSound`, a two-case value: `.event(String)` or
  `.file(String)`. The file is a name in the Sounds folder
  (`~/Documents/Proteles/Sounds/`), resolved the way the player already
  resolves cue files.
- `Trigger` gains `sound: TriggerSound?`. Stored triggers without it decode
  as before; the tolerant decoder already handles added fields this way.
- `TriggerFiring` carries the sound through.

**MudCore: emitting the event**

- In `ScriptEngine.processTriggerFirings`, a firing with a sound builds a
  `SemanticEvent` and passes it to `nativePlugins.onSemanticEvent`:
  - **source** `.pattern(rule: "trigger.<name or id>")`. A trigger is a
    prose match, the weakest tier. This is the same convention the user's
    notification rules already use (`user.<label>`), so `Source` needs no
    new case;
  - **name and category**: for `.event(e)`, `e` and its vocabulary
    category. For `.file(f)`, `trigger_sound` in the new category (below),
    with the file in the payload (`["file": f]`).
- The resulting effects go in `disposition.effects`, beside the trigger's
  sends and scripts. They therefore apply **whether or not the line is
  displayed**, as MUSHclient's do. A trigger that hides a spam line and
  plays a sound keeps working.
- No per-line cost: this runs only when a trigger with a sound fires.

**MudCore: the cue map**

- A new category, **`custom`**: "something your own trigger matched". The
  layer can't know what a user's pattern means, so it doesn't guess. It
  gets a category volume like every other (`spcat custom 40`).
- The **`trigger_sound`** event in the vocabulary. `Soundpack` plays the
  payload's file for it, at `min(trigger_sound, custom, master)`, so
  `spset trigger_sound volume 50` also works.
- **Playback discipline** keys `trigger_sound` cues on their file, not the
  shared event. Otherwise two different trigger files inside 0.25 s would
  collapse into one, as if they were one thing happening. Every other
  event keeps keying on the event.

**Import (MUSHclient → Proteles)**

- World-file and plugin-XML triggers map `sound="…"` to `.file(<name>)`,
  keeping only the file name. `"(No sound)"` and empty values map to none.
- A file that isn't in the Sounds folder plays nothing, or the
  system-alert fallback if that's on, which is the player's existing
  behaviour for a missing cue. The Light plugins' Windows path lands
  there. No error is shown.

**MudUI: the trigger editor**

- A **Sound** section after Highlight, with a picker for None, Event or
  File:
  - **Event**: a menu of the vocabulary names, grouped by category;
  - **File**: a menu of the files in the Sounds folder, plus "Add file…",
    which copies a chosen file into the folder. The trigger stores the
    name, not a path, so it travels with the profile and works on iOS.
- A caption: "Plays through the soundpack. `spmute` turns sound on and
  off." See §6, Q1.

## 4. Options considered

- **A. The trigger emits an event; the cue map plays it. Proposed.** This
  is what #83 and D-127 specify, and it is the only option where volume
  caps, variants, discipline and mute apply without a second copy.
- **B. The trigger emits a `.playSound` cue directly** (what a Lua
  `PlaySound` does). Simpler, but it is the "raw play-file call" #83 rules
  out, and it skips category volume, which the exit criterion requires.
  Rejected.
- **C. Put `trigger_sound` in an existing category** (`system`) instead of
  adding `custom`. That makes `spcat system 0`, meant for INFO and market
  noise, silence your own trigger sounds as well. Rejected. The category
  list grows anyway in step 5, where notification sounds get their own.
- **D. Port `sound_if_inactive`.** No real data uses it, and MudCore would
  need to know whether the window is focused. Not proposed. It is one Bool
  plus a check if someone asks.
- **E. Map the `sound` argument of Lua `AddTriggerEx`/`AddTrigger`.** No
  plugin in the corpus passes one, and it would change the
  `proteles.addTrigger` host function. Not proposed.

## 5. What does not change

- **Which events the layer classifies**, the corpus event pins and the cue
  pins. The replay counter doesn't run user triggers.
- **Matching:** `TriggerEngine` decides as today; the sound rides on the
  firing.
- **Plugin triggers** keep working as before. They gain a sound only
  through the XML import mapping above.
- **Notification-rule sounds** (step 5), **Settings ▸ Audio** (step 6) and
  any preview button in the editor.
- **Aliases and timers:** no sound action. That is outside #83's task.

## 6. Open question

**Q1 — Does the soundpack's mute silence trigger sounds?** The soundpack
is **muted by default**, and today its mute is the gate for *every*
`.playSound` (`SessionController+Scripting.swift`), including S&D's and
other plugins'.

- **(a) Yes, both kinds. Proposed.** One switch for all sound, as today,
  and no new setting (D-122). The cost: a new player who adds a trigger
  sound hears nothing until `spmute`, hence the editor caption.
- **(b) No, file sounds play regardless**, like notification sounds under
  D-127 (4). This matches MUSHclient, where trigger sounds have their own
  switch and the soundpack is just a plugin. But "muted" would no longer
  mean silent, and a trigger picking a vocabulary event would still follow
  the mute, so the two kinds would behave differently.

I recommend (a). The user can unmute once, and the next step's
notification exemption stays the only exception, with a stated reason.

## 7. Tests

- **`Trigger` decode:** a stored trigger without `sound` decodes to nil;
  one with each kind round-trips.
- **Emission (`ScriptEngine`):**
  - an event-sound trigger yields that event's cue;
  - a file-sound trigger yields a cue for its file at
    `min(trigger_sound, custom, master)`;
  - a gagging trigger with a sound still yields the cue;
  - a muted soundpack yields none (per Q1 (a));
  - a trigger without a sound emits no event.
- **`CueGovernor`:** two `trigger_sound` cues with different files inside
  the gap both play; the same file inside the gap collapses.
- **Import:** world-file and plugin-XML `sound=` map to `.file(name)`
  (Windows path reduced to the name); `"(No sound)"` and empty map to nil.
- **Commands:** `spcat custom` and `spset trigger_sound volume` accept and
  list the new names.

## 8. Hot path and impact

- **Per firing of a trigger that has a sound:** one event value and one
  registry fan-out, the same work a classified line already costs.
  Triggers without a sound pay one nil check. No A/B proposed.
- **Behaviour:** nothing audible changes until a player gives a trigger a
  sound. An imported MUSHclient trigger with a sound now tries to play it,
  where today the attribute is dropped.
- **Files:** `TriggerEngine.swift` (or a new `TriggerSound.swift`),
  `ScriptEngine+Process.swift`, `SemanticEvent.swift` (the `custom` case),
  `SemanticEventVocabulary.swift`, `Soundpack.swift`, `CueGovernor.swift`,
  `MUSHclientWorldFile.swift`, `MUSHclientScriptMapping.swift`,
  `PluginMapping.swift`, `TriggerEditorView.swift` (MudUI), and tests.
- **Live check for you:** give a GUI trigger a file sound and an event
  sound, with `spcat custom` at a low volume, then fire each.

## 9. Implementation notes (2026-10-27)

- **Files as built:** `TriggerSound.swift` (the value, its event, and
  `imported(_:)` for MUSHclient's attribute); `Trigger.sound` and
  `TriggerFiring.sound`/`triggerName` in `TriggerEngine.swift`; emission
  in `ScriptEngine+Process.swift`; `SemanticEvent.Category.custom` and
  the vocabulary's `custom` set; `SoundpackConfig.triggerCue(file:)` and
  the `trigger_sound` branch in `Soundpack.onSemanticEvent`; the
  per-file key in `CueGovernor`; `sound` through `MUSHclientWorldFile`,
  `MUSHclientScriptMapping` and `PluginMapping`; the editor section in
  `MudUI/Scripts/TriggerSoundSection.swift`.
- **The event's source name** is the trigger's name, else its id.
- **`spset trigger_sound wav …`** is accepted but has no effect: each
  trigger names its own file. Left as is.
- **Tests:** `TriggerSoundTests` (10): event and file sounds, the
  `custom` and per-event caps, a gagging trigger still playing, the mute,
  the silent cases, the event's shape, storage, the per-file governor key,
  and import. `SemanticEventVocabularyTests` counts the trigger's file
  sound as a third built-in source of event names.
- **Live check** (`session-20261027-155044`): a file sound on a trigger
  matching `eq`'s `You are using:` played. A first attempt used
  `You are carrying:`, which never reaches triggers on this setup: the
  inventory plugin sends `invdata` for `i` and draws that heading as a
  local note.
