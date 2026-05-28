# TTS / accessibility — plan + first implementation

> Plan deliverable (no code). Builds on the recorded design (D-41). Goal: make
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

**Decision:** default to `AVSpeechSynthesizer` (full control, works without
VoiceOver — most VI MUDders run a dedicated app voice). Offer a preference
"Route through VoiceOver" for users who want unified speech+braille and already
run VoiceOver. Detect VoiceOver running (`NSWorkspace.shared
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

- **Phase 1 (MVP, ship first):** `SpeechFilter` + `TextToSpeech` plugin +
  `SpeechController` with `AVSpeechSynthesizer`. Commands: `tts on/off`,
  `tts rate`, `tts voice`, `tts stop`, `tts say <text>`, `tts last`. Speak
  *incoming lines* with a sensible default gag set (map/gauges/blank) and
  prompt-interrupts-queue behaviour. Preferences: enable, rate, voice, "speak
  all lines vs only flagged channels".
- **Phase 2:** `proteles.speak` host call (scripts/plugins speak); per-channel
  speak toggles wired to the Chat capture; "read room / read vitals" commands
  pulling from GMCP state; key bindings (needs MacroEngine).
- **Phase 3:** VoiceOver-announcement routing option (speech + braille);
  symbol-pronunciation dictionary; "review buffer" navigation (read previous N
  lines) — Aardwolf's review-buffer feature for VI users.

## Decisions for the user
1. **MVP scope** — is "speak incoming lines + on-demand commands + rate/voice"
   the right first cut? (Recommended.)
2. **Default on or off?** Off by default (it's an accessibility opt-in); but
   easily discoverable in Preferences ▸ Accessibility.
3. **VoiceOver routing** — Phase 1 or defer to Phase 3? (Recommend defer;
   `AVSpeechSynthesizer` covers most.)
4. Should we reach out to an actual Aardwolf VI player to validate the gag
   defaults + command set before shipping? (Strongly recommended — this is a
   domain where guessing the UX is risky.)

## Effort
Phase 1: medium (a pure filter + a NativePlugin + an AVFoundation controller).
No new dependencies. The risk is *UX correctness*, not implementation — hence
the recommendation to validate with a real user.
