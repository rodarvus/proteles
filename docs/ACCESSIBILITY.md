# Proteles & Accessibility

Aardwolf has a long-standing visually-impaired community, mostly playing on
MUSHclient with a screen reader. Proteles should serve that community as a
first-class audience, not as an afterthought.

This page describes the current public state. The detailed architecture
proposal lives in
[docs/plans/ACCESSIBILITY_REVIEW.md](plans/ACCESSIBILITY_REVIEW.md), and the
active tracking issue is
[GitHub issue #9](https://github.com/rodarvus/proteles/issues/9).

## Current Status

Accessibility is still in design and validation. Proteles has app-owned speech
features and some labelled controls, but native VoiceOver support for live MUD
output is not yet proven good enough for screen-reader play.

The next accessibility milestone is a native VoiceOver output path:

- Every visually displayed MUD output line should reach VoiceOver.
- Lines should be spoken in display order.
- New lines should queue behind current speech instead of interrupting it.
- VoiceOver focus should remain on the command input while output is spoken.
- Players need a review path for missed or stopped speech.

Until that has been implemented and validated with screen-reader users, the
existing speech features should be treated as useful support, not parity.

## What Works Today

- **Keyboard-first command input.** The command input is intended to stay ready
  for typing during normal play.
- **App-owned text-to-speech.** Proteles can speak displayed game text through
  the macOS speech synthesizer.
- **VoiceOver announcement routing.** Speech requests can be routed through
  macOS accessibility announcements, but this is not yet the reliable queued
  live-output model described above.
- **Recent-line speech commands.** `tts last` and `tts review` provide a basic
  spoken recovery path.
- **Native soundpack.** Event cues are available for combat, channels, quests,
  repops, and other events. They are muted by default.
- **Some labelled controls.** The command input, output, map, keypad editor,
  command buttons, and connection surfaces have partial accessibility labels.
- **Color is not the only signal.** Important status is also represented through
  text, numbers, position, or shape.

## Known Gaps

- Live MUD output is not yet a dependable native VoiceOver stream.
- Output review is not yet designed as a full screen-reader workflow.
- Semantic review buffers for tells, channels, URLs, command captures, vitals,
  and other high-value streams are still planned work.
- Compound UI elements need semantic grouping. For example, a health bar should
  expose one useful accessibility element rather than many decorative pieces.
- Braille support needs validation with real hardware and VoiceOver workflows.
- Aardwolf-side settings such as `blindmode`, `tags`, `spamreduce`, and `brief`
  are not yet managed by an explicit Proteles helper.

## Text-To-Speech Commands

TTS is off by default. Enable it from **Settings -> Audio**, or type `tts alerts`
or `tts on` in the command input.

| Command | Effect |
| --- | --- |
| `tts on` / `tts alerts` / `tts off` | Set the speech mode. |
| `tts say <text>` | Speak text immediately. |
| `tts stop` | Stop talking and clear the queue. |
| `tts last [n]` | Re-speak recent displayed lines. |
| `tts review [...]` | Move through the spoken recent-line buffer. |
| `tts vitals` | Speak current HP, mana, and moves. |
| `tts rate <wpm>` | Set app speech rate. |
| `tts voice <name>` | Pick a macOS voice for app speech. |
| `tts prompts off\|delta` | Control prompt verbosity. |
| `tts mute <channel>` / `tts unmute <channel>` | Mute or restore a channel. |
| `tts subst add <from> <to>` | Add a pronunciation substitution. |
| `tts subst del <from>` | Remove a pronunciation substitution. |
| `tts enter` | Toggle stopping speech when sending a command. |
| `tts running` | Toggle quiet mode while speedwalking. |
| `tts focus` | Toggle quiet mode while Proteles is not frontmost. |
| `tts setup` | Show Aardwolf-side screen-reader setup tips. |

Scripts and plugins can request speech with `proteles.speak(text[, interrupt])`.

## Aardwolf-Side Settings

Aardwolf already provides several screen-reader-oriented tools. Proteles should
not silently change these settings, because some of them affect privacy and
social discoverability.

Relevant Aardwolf features include:

- `blindmode 0|1|2`
- `tags`
- `spamreduce`
- `brief`
- `catchtells`, `savetells`, and `replay`
- `glance`

Future Proteles work may add an explicit, reversible helper for these settings.
For now, use Aardwolf's own help files and commands.

## How To Help

The highest-value feedback is a screen-reader recording of real play:

- connecting and logging in;
- reading live output while keeping focus on the command input;
- typing commands while output arrives;
- reviewing missed lines;
- selecting and copying output;
- opening links;
- using channels, tells, and high-volume combat or quest output;
- using a braille display, if that is part of your workflow.

Please add findings to
[issue #9](https://github.com/rodarvus/proteles/issues/9). Concrete examples
are especially useful: what was spoken, what was missed, where focus moved, and
what you expected instead.
