# S1 step 2 — the event→cue map as data

> **Status: proposed 2026-10-27, awaiting approval.** Tracking: **#83**.
> Builds on step 1 (`fde0ef1c`, every cue now comes from `onSemanticEvent`)
> and the design answers in **D-127**.

## 1. The ratified scope, verbatim

From **#83**, the first task:

> Event→cue map **as data**: per-event and per-category volumes under a
> master cap, pan, variants

From **D-127**:

> (2) **Category volume is a cap**, like the reference's master: effective =
> min(event, category, master), so volumes tuned in MUSHclient carry over
> unchanged.

> (5) **Variants** (several files per event, one picked per firing) are
> built. Compatibility is owed in the MUSHclient → Proteles direction only;
> an architecture element may be improved once inside Proteles. An imported
> event becomes a one-file list, and Proteles's own earlier `soundpack.json`
> is converted once on first load

And from the audit #83 quotes, the problem this answers:

> Closed 69-event vocabulary, console-only configuration, … no categories

### 1.1 My reading

"As data" is about **the mapping**: which event plays which files, at what
volume and pan. That mapping becomes one value the soundpack reads and the
console (and later Settings ▸ Audio) edits. It stops being lookups
hard-wired into `Soundpack`, and it is keyed by **any first-party event
name**, not only the reference's 69. It does not mean moving the
reference's default table out of Swift into a resource file (§4, option B).

## 2. Where things stand

- **Defaults:** `SoundEventClassifier.defaults`, 69 entries, each one file
  plus a description. Volume 100 and pan 0 for every event.
- **User deviations:** `SoundpackConfig` in `Settings/soundpack.json`:
  `muted`, `globalVolume`, `debug`, `systemSoundFallback`, and per-event
  `volume`/`pan`/`file`.
- **Gain:** `Soundpack.cueEffects` computes `min(event, global)` → dB →
  linear.
- **Vocabulary:** `spset`, `sptog` and `spfire` accept only the 69
  reference names. The layer also produces six tag-sourced events
  (`affect_on`, `affect_off`, `recovery_on`, `recovery_off`, `cast_failed`,
  `skill_gain`); none of them can be given a cue today.
- **Other readers of the file:** `AudioSettingsView` reads and writes
  `muted`/`globalVolume`; `CuePlayerController` reads
  `systemSoundFallback`.
- **Import:** the MUSHclient importer copies the `.wav` files only. The
  reference's per-event volumes live in plugin state, which isn't imported
  today. That stays out of scope (§3).

## 3. What changes

**Types (MudCore, `Audio/`)**

- **`SoundpackConfig` becomes the cue map**, version 2:
  - `events[name]`: `volume`, `pan`, and `files: [String]` (replaces
    `file`).
  - New `categories[category]`: a volume per `SemanticEvent.Category`, 100
    by default; only deviations are stored, as today.
  - `muted`, `globalVolume` (the master), `debug` and `systemSoundFallback`
    keep their names. They are the reference's names, and the app reads
    them.
- **A pure cue function** on the config:
  `cue(for event: SemanticEvent, pick:) -> SoundCue?`.
  - Gain = `min(event, category, master)` → the existing dB → linear curve.
  - Pan as today.
  - The file is picked from the event's list.
  - `Soundpack.cueEffects` calls it. An event with no files, or with any of
    the three levels at 0, plays nothing.
- **Open vocabulary:** any name in `SemanticEventVocabulary` can carry
  files. The defaults stay the reference's 69; nothing new is bundled. A
  player can, for example, `spset affect_off wav spell_off.wav`. Names
  outside the vocabulary are still rejected, so there are no user-defined
  events (D-122).

**Migration (`SoundpackConfig+Migration.swift`)**

- A file without `version` is read as version 1: `file` becomes
  `files: [file]`, and everything else carries over.
- It is saved straight back as version 2.
- The converter lives in its own file so it can be deleted in a later
  release.

**Console (the `sp*` surface, retained per #83)**

- `spset <event> wav <file>`: sets the list to that one file (as today).
- `spset <event> wav add <file>` / `wav remove <file>`: variants.
- `spset <event> wav default`: as today.
- `spset` listing: a variant list shows as `a.wav +2`.
- **New `spcat`:** lists the eight category volumes; `spcat <category>
  <0-100>` sets one. A setting is confirmed with the existing
  `channel_on.wav` cue, as `spvol` does.
- `spset`, `sptog` and `spfire` accept any vocabulary name. `sptog all`
  still toggles only events that have files.

## 4. Options considered

- **A. Defaults stay a Swift table; user deviations in JSON. Proposed.**
  The defaults table is already data: a transcription, checked complete by
  test against the vocabulary. The map is what becomes editable.
- **B. Ship the defaults as a bundled JSON resource.** It reads as "more
  data", but nobody edits it (the user edits deviations), it adds resource
  loading to MudCore on both platforms, and it loses the totality test's
  compile-time link. Rejected.
- **C. Keep `file` and add `files` beside it, readable forever.** No
  migration step, but two shapes to decode for good. D-127 chose a one-time
  conversion. Rejected.
- **Rename the file to `sound.json`?** The feature outgrows "soundpack"
  once notifications and triggers join (steps 5–6). A rename costs one
  extra line in the migration. I'd leave the name until the Settings step,
  where the user-facing naming gets settled in one place. Your call.

## 5. What does not change

- `SoundCue` and its shape: carrying the event and category is step 3,
  with playback discipline.
- The player, file resolution, the system-alert fallback, `spmute`/`spvol`
  semantics, the Chat Echo mute, and inline `!!SOUND` (still under
  `remote_sound`'s volume).
- No new default cues and no new bundled files.
- No Settings ▸ Audio UI; that is its own step.
- Triggers and notification sounds (later steps).
- MUSHclient import of per-event volumes. It isn't done today, and adding
  it would be new scope.

## 6. Two decisions I need from you

1. **Variant picking.** Uniform random repeats the same file half the time
   with two variants, which sounds like having no variants. **Proposed:**
   random, but never the same file twice in a row for an event. That needs
   one remembered index per event in the plugin, not persisted. The
   alternative is plain uniform random.
2. **`spcat` as a new console command now**, or category volumes settable
   only from the Settings step later. **Proposed: now.** #83 keeps the
   console as a surface over the same store, and without it the category
   cap can't be used or live-tested until the UI lands.

## 7. Tests

- **Migration:** a version-1 fixture (shaped like today's file, with a
  custom `file`, volume and pan) loads as version 2 with `files: [file]`
  and is rewritten as version 2. A file missing every optional key still
  loads (tolerant decoding, as today).
- **Cap:** event 80, category 50, master 100 gives 50; each of the three
  set to 0 silences; the curve matches `SoundVolume`.
- **Variants:** with an injected picker, `add`/`remove` edit the list, and
  the no-repeat rule holds over 1,000 picks of a 2-file and a 3-file list;
  a 1-file list always plays that file.
- **Open vocabulary:** `spset affect_off wav x.wav` and then an
  `affect_off` tag event plays `x.wav`; an unknown name is rejected.
- **`spcat`:** list, set, validation.
- **Corpus:** re-run the gated replay. With the default config the cue pins
  must be identical: defaults are one file each, so the pick is
  deterministic.

## 8. Hot path and impact

- **Not a per-line or per-packet change.** The cue function runs per
  classified event, only while the soundpack is unmuted, and replaces the
  lookups `cueEffects` does today with the same number of dictionary reads
  plus one category read. Proposed: no A/B; the corpus re-run proves the
  cues are unchanged. Say if you want one anyway.
- **Behaviour:** none with an unedited config. New capability: variants,
  category caps, and cues on the six tag events.
- **Regression risk:** the migration losing a custom setting. The fixture
  test covers the shape; your own file has no event overrides today, so
  your live check is that `spset` still lists everything at 100.
- **Files:** `SoundpackConfig.swift` (+ `+Migration`),
  `Soundpack.swift`, `Soundpack+Commands.swift` (242 lines, room to grow),
  and tests. No app-target changes; `AudioSettingsView` keeps compiling
  against the same property names.
