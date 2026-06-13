# Proteles & accessibility — for visually-impaired players

Aardwolf has a long-standing visually-impaired (VI) community, mostly playing on
MUSHclient with a screen reader. Proteles is built to serve that community as a
first-class audience, not an afterthought. This page is the honest state of
things: **what works today, how to turn it on, how to use it, what's still
coming, and how to help us get it right.**

> **Status (v0.8.0):** the text-to-speech engine and screen-reader routing ship
> and are usable. The remaining work is **validation with real VI players** and
> some depth features — tracked in
> [GitHub issue #9](https://github.com/rodarvus/proteles/issues/9). If you play
> Aardwolf with a screen reader, your feedback there is exactly what we need.

---

## What works today

- **Text-to-speech (TTS).** Proteles can speak game text — either through its own
  voice or by routing to **VoiceOver** (so speech *and* braille go through your
  own assistive settings).
- **A native soundpack.** Event cues (combat, channels, quests, repop). Muted by
  default; opt-in.
- **Keyboard-first by design.** Every primary action has a key path; the command
  input is always focused and ready. This is core to the app, not a bolt-on.
- **Labelled controls.** The command input, the game output, the worlds list, and
  the map carry VoiceOver labels; the output text is navigable.
- **Colour is never the only signal.** The vitals bars have a numbers mode, the
  group panel states "most hurt"/leader in words, the worlds list says "active
  world", and the map speaks the current room/area.

## What's still coming (and why this page says "usable", not "done")

These are deferred under #9 until we've validated with real VI players:

- **Vitals/HUD value announcements** — the graphical gauges aren't yet spoken as
  values (use `tts vitals` on demand, below).
- **A pronunciation dictionary** beyond the per-player substitutions you can add.
- **Review-buffer navigation** richer than `tts last` / `tts review`.
- A **full VoiceOver narration pass** over every screen.

We would rather ship this honestly and iterate with you than claim parity we
haven't proven. **Please tell us what's awkward.**

---

## Turning TTS on

TTS is **off by default** (so it never surprises a sighted user). Two ways to
enable it:

- **In the app:** **Settings ▸ Audio** — choose the speech mode and, if you use a
  screen reader, turn on **VoiceOver routing**.
- **By command, in the game:** type `tts alerts` or `tts on`.

There are three modes:

| Command | What it speaks |
| --- | --- |
| `tts off` | nothing |
| `tts alerts` | tells, and anything important enough to fire a sound cue |
| `tts on` (or `tts everything`) | all displayed game lines |

Speech runs on what's actually **displayed** — anything gagged by the map,
gauges, or a plugin is never spoken — and **tells interrupt** so you hear them
over slower combat narration. Symbol art and box-drawing are stripped before
speaking.

### Two ways the speech reaches you

1. **Proteles' own voice** (the default): the macOS speech synthesizer, with full
   control over rate and voice from the `tts` commands or Settings ▸ Audio.
2. **Routed to VoiceOver / your assistive tech** (turn on *VoiceOver routing* in
   Settings ▸ Audio): Proteles posts each line as a VoiceOver announcement, so it
   speaks **and brailles** through the settings, voice, and rate you already use
   everywhere else.

Use whichever fits your setup. If you run VoiceOver full-time, routing keeps
everything consistent with the rest of your Mac.

---

## The `tts` command reference

Type these in the game's command line. `tts help` lists them in-app; `tts setup`
gives Aardwolf-side advice (blindmode, spam reduction, prompt).

| Command | Effect |
| --- | --- |
| `tts on` / `tts alerts` / `tts off` | set the speech mode |
| `tts say <text>` | speak something immediately (jumps the queue) |
| `tts stop` | stop talking and clear the queue |
| `tts last [n]` | re-speak the last *n* displayed lines |
| `tts review [...]` | move through the recent-line review buffer |
| `tts vitals` | speak your current HP/mana/moves on demand |
| `tts rate <wpm>` | speaking rate, 80–600 words per minute |
| `tts voice <name>` | pick a voice (Proteles' own-voice mode) |
| `tts prompts off\|delta` | how much of the prompt to speak |
| `tts mute <channel>` / `tts unmute <channel>` | silence/restore a channel's speech |
| `tts subst add <from> <to>` / `tts subst del <from>` | pronunciation fixes (and `!skip` to drop a phrase) |
| `tts enter` / `tts running` / `tts focus` | toggle: stop on send / quiet while speedwalking / quiet when Proteles isn't frontmost |
| `tts setup` | Aardwolf-side VI setup tips |

Scripts and plugins can speak too, via `proteles.speak(text[, interrupt])`.

### The soundpack

Sound cues are muted by default. Enable them in **Settings ▸ Audio**, or with the
`spmute` / `sptog` / `spvol` commands (`sphelp` lists them).

---

## Testing it & telling us what's wrong

If you play with a screen reader, here's what would help most:

1. Turn on **VoiceOver routing** (Settings ▸ Audio), connect, and just play for a
   bit. Does the narration keep up? Do tells cut through? Is anything double-spoken?
2. Tab/VoiceOver-navigate the chrome — the command input, the worlds list, the
   map. Are the labels clear? What's unlabelled or confusing?
3. Try `tts vitals`, `tts last 3`, `tts rate 350`, `tts mute <a noisy channel>`.
4. Tell us what's missing for *your* workflow — pace, verbosity, what should and
   shouldn't be spoken.

Please file findings on **[issue #9](https://github.com/rodarvus/proteles/issues/9)**
(or reach the author in-game). Concrete "X was annoying / Y wasn't spoken /
Z should be an option" reports are gold — they're how this gets good.
