# TTS / accessibility — plan + first implementation

> **Status: shipped (feature-complete for 1.0). Historical design doc — kept
> for the research + rationale below.** Implemented 2026-06-11
> ([`../DECISIONS.md`](../DECISIONS.md) D-110) as `SpeechFilter` + the
> `TextToSpeech` native plugin + the app's `SpeechController` (both backends —
> app voice AND VoiceOver routing), with Settings ▸ Audio. Issue #9 stays open
> only for the deferred phase-3 items (symbol-pronunciation dictionary,
> review-buffer navigation, macro key-chords) + VI-player validation.
>
> One design refinement landed in the implementation: `SpeechFilter` runs on
> **displayed** lines (post-gag, beside `notifyForOutput`), so plugin/map/gauge
> gags never reach it — simpler and more correct than re-deriving gag rules
> here (see D-110).

> Original plan deliverable (no code). Built on the recorded design
> ([`../DECISIONS.md`](../DECISIONS.md) D-41). Goal: make
> Proteles usable by blind / visually-impaired (VI) Aardwolf players, and useful
> for sighted players who want spoken alerts.

## Who this is for + what they actually need (research)

MUD VI players are a real, dedicated community (Aardwolf has long-standing
blind players; MUSHclient + the "MushReader"/Tolk soundpack and Mudlet's
`ttsSpeak` exist precisely for them). Synthesising the established needs:

1. **Speak incoming text as it arrives** — but *selectively*. Reading every
   line is overwhelming in combat. VI users rely heavily on:
   - **Interrupt vs queue**: a new prompt/important line should be able to
     **interrupt** the current utterance (combat moves fast); other text queues.
   - **Gag/filter**: skip the map, gauges, decorative ASCII, repeated spam.
   - **Rate control**: experienced screen-reader users run *fast* (300–500
     wpm); rate must go well past the macOS default.
2. **Speak on demand**: "read the last line", "read current room", "read my
   vitals/affects", "stop talking" — bound to keys (ties into MacroEngine).
3. **Punctuation/symbol handling**: MUD output is full of `*`, `=`, `|`,
   `@`-codes; these must be stripped/normalised before speaking or they're read
   aloud as "asterisk asterisk asterisk".
4. **Braille** matters too (Tolk routes to braille displays). On macOS, routing
   through **VoiceOver announcements** reaches the user's configured braille
   display + speech automatically; app-controlled `AVSpeechSynthesizer` does not.
5. **Don't fight the screen reader**: if VoiceOver is already reading the
   window, app TTS must not double-speak. Two distinct modes are needed.

Mudlet's API (`ttsSpeak`, `ttsSkip`, `ttsQueue`, `ttsSetRate`, `ttsSetVoice`,
`ttsPause/Resume`, `ttsGetQueue`) is the de-facto scripting surface to mirror.

## macOS technology choice (two correct paths — must not double-speak)

- **`AVSpeechSynthesizer`** — app-controlled voice/rate/queue/interrupt. The
  right engine for *app-driven* spoken output (the soundpack-style "speak the
  MUD"). Modern (`NSSpeechSynthesizer` is legacy). Rate, voice, pitch, volume,
  and a real utterance queue with interrupt.
- **VoiceOver announcements** (`NSAccessibility.post(element:, notification:
  .announcementRequested, userInfo:)`) — speaks *and* brailles via the user's
  AT settings; the accessibility-correct path that respects the user's screen
  reader. But you can't control rate/voice (the user owns those).

**Decision (shipped):** default to `AVSpeechSynthesizer` (full control, works
without VoiceOver — most VI MUDders run a dedicated app voice), with a
preference "Route through VoiceOver" for users who want unified speech+braille
and already run VoiceOver. Both backends were built in v1 (the VoiceOver path
was *not* deferred — see D-110). Detect VoiceOver running (`NSWorkspace.shared
.isVoiceOverEnabled`) to warn against double-speak.

## Architecture (mirrors the actor/engine split)

- **MudCore `SpeechFilter` (pure, value-type, unit-tested)** — decides *what*
  to speak from a `Line`: strip `@`-codes/ANSI, normalise symbols, apply
  gag/spoken-channel rules, classify priority (prompt/tell/combat/normal →
  interrupt or queue). The brain; no AppKit. Fully testable.
- **MudCore effect** `.speak(text, interrupt:)` + host call `proteles.speak`
  (so scripts/plugins can speak — the `ttsSpeak` analog).
- **MudCore `TextToSpeech` NativePlugin** — policy + `tts …` commands
  (`tts on/off`, `tts rate N`, `tts voice X`, `tts say …`, `tts stop`,
  `tts last`) + persisted settings (per world, via NativePluginStore). Routes
  lines through `SpeechFilter`, emits `.speak` effects.
- **macOS `SpeechController` (app target)** — owns the `AVSpeechSynthesizer`
  (or VoiceOver-announcement path), applies the `.speak` effects, manages the
  queue/interrupt/rate/voice. The only AppKit/AVFoundation piece.

This keeps the decision logic testable in MudCore and the platform engine thin.

## Phased delivery

Phases 1 and 2 shipped together (D-110); Phase 3 is the remaining work tracked
on issue #9.

- **Phase 1 (MVP, ship first):** `SpeechFilter` + `TextToSpeech` plugin +
  `SpeechController` with `AVSpeechSynthesizer`. Commands: `tts on/off`,
  `tts rate`, `tts voice`, `tts stop`, `tts say <text>`, `tts last`. Speak
  *incoming lines* with a sensible default gag set (map/gauges/blank) and
  prompt-interrupts-queue behaviour. Preferences: enable, rate, voice, "speak
  all lines vs only flagged channels".
- **Phase 2:** `proteles.speak` host call (scripts/plugins speak); per-channel
  speak toggles wired to the Chat capture; "read room / read vitals" commands
  pulling from GMCP state; key bindings (needs MacroEngine).
- **Phase 3 (deferred — issue #9):** symbol-pronunciation dictionary; "review
  buffer" navigation (read previous N lines) — Aardwolf's review-buffer feature
  for VI users; macro key-chords. *(VoiceOver-announcement routing, listed here
  in the original plan, was instead built in v1 — see D-110.)*

## Decisions (resolved at ship time, D-110)
1. **MVP scope** — "speak incoming lines + on-demand commands + rate/voice" was
   the first cut, plus an `alerts` mode that reuses the soundpack classifier as
   the "worth announcing" oracle.
2. **Default on or off?** Shipped **off by default** (accessibility opt-in),
   discoverable under Settings ▸ Audio.
3. **VoiceOver routing** — built in **v1** (not deferred), per the user's
   decision; `AVSpeechSynthesizer` is the default backend.
4. **Validate with a real VI player** — still pending; tracked on issue #9
   before it closes (this is a domain where guessing the UX is risky).

## Effort (as shipped)
Phase 1+2 was medium (a pure filter + a NativePlugin + an AVFoundation /
NSAccessibility controller). No new dependencies. The risk was *UX
correctness*, not implementation — hence the open #9 item to validate with a
real user.
