# Accessibility Architecture Proposal

Status: proposed, 2026-06-19. Tracks GitHub issue #9.

## Summary

Proteles should treat native VoiceOver output as the first accessibility
milestone. Every line displayed in the main MUD output should reach VoiceOver in
display order, queue behind any line already being spoken, and leave VoiceOver
focus on the command input so the player can keep typing.

That live VoiceOver path is the spine. Output review, semantic review buffers,
UI accessibility cleanup, and optional server-setting helpers build on top of
it. App-owned text-to-speech remains useful, but it is a fallback or alternate
speech path, not the primary design for full-time VoiceOver users.

## Goals

- Make live MUD output usable through native VoiceOver.
- Preserve the command input as the active focus while output is spoken.
- Provide a recovery path for missed or stopped speech.
- Support braille by keeping output and review surfaces navigable through
  VoiceOver, not only through app speech.
- Preserve Aardwolf-specific behavior by using documented server features and
  reference clients instead of inventing protocol guesses.
- Keep server-side preference changes explicit, reversible, and secondary.

## Non-Goals

- Do not invent a new telnet or GMCP screen-reader protocol.
- Do not auto-detect screen-reader users.
- Do not silently change the user's Aardwolf privacy state, including
  `blindmode 1` vs `blindmode 2`.
- Do not treat broad UI control labelling as a substitute for accessible MUD
  output.
- Do not claim parity until tested by screen-reader users in live play.

## User Feedback

Feedback from a blind Aardwolf player who works professionally in accessibility
QA reshaped this proposal.

Initial feedback:

- App-specific TTS is less important than making VoiceOver routing work.
- The UI needs accessibility help.
- The shipped client was not usable for casual blind play.

Follow-up feedback clarified the priority order:

- The first important task is native VoiceOver support for the output.
- Every visually displayed output line should be spoken through VoiceOver, in
  display order.
- New lines should queue behind the current utterance rather than interrupting
  it.
- VoiceOver focus should remain on the command input while output is spoken.
- Falling behind is normal for screen-reader MUD play; users need a way to
  review missed lines after stopping or pausing speech.
- `blindmode 1` and `blindmode 2` produce the same output. The difference is
  privacy: `1` lets other players find the user via `who blind` / `who vi`;
  `2` is private.
- Braille support is still worth including even if this reviewer does not MUD
  quickly in braille.
- Later UI cleanup should aggregate compound controls. For example, a health
  bar should be one useful accessibility element, not many decorative pieces.

## Aardwolf Ground Truth

The original plan assumed Proteles would need to advertise screen-reader use via
telnet (`NEW-ENVIRON SCREEN_READER` or MTTS bit 64) and coordinate a new server
mode. That was wrong.

Aardwolf already has relevant server-side features:

- `blindmode 0|1|2`: server-side simplified output and VI-specific room text.
  Modes `1` and `2` produce the same output; the difference is public vs private
  visibility to other players.
- Conditional authoring codes: `@A..@E` hides text from blindmode users, while
  `@F..@H` shows text only to blindmode users.
- `tags`: structured-output markers around rooms, exits, channels, tells,
  scores, equipment, inventory, and other game output.
- `spamreduce`: server-side spam reduction with `save` and `restore`.
- `brief`: controls room-description verbosity.
- `catchtells`, `savetells`, and `replay`: server-side tell queueing.
- `glance`: short room look, though live testing showed `automap` can still
  force map output.

The 2026-06-15 live recording captured the relevant help files and command
outputs. At that time:

- Enabled tags included `BIGMAP`, `COORDS`, `EXITS`, `HELPS`, `MAP`,
  `MAPEXITS`, `MAPNAMES`, `ROOMDESCS`, `ROOMNAMES`, `ROOMCHARS`, `ROOMOBJS`,
  `SKILLGAINS`, `SPELLUPS`, and `SCAN`.
- Disabled tags included `CHANNELS`, `TELLS`, `SAYS`, `SCORE`, `EQUIP`, `INV`,
  `EDITORS`, `REPOP`, `WHERE`, `COMMANDS`, `QUIET`, `TELOPTS`, and `MAPDATA`.
- `automap` and `maprun` were on, although Aardwolf VI tips recommend turning
  both off for screen-reader play.
- VI help also recommends reducing punctuation/noise and using channel history.

One earlier mapper concern was resolved by the same recording: Vidblain is a
coordinate-gridded VI continent, and the observed "blue rune / castle doors"
behavior was an area mechanic, not a Proteles mapper issue.

## Current Proteles State

What already exists:

- Some accessibility labels are present:
  - `ConnectionManagerView`: world rows have labels and identifiers.
  - `MapPanelView`: the map canvas has a label and value.
  - `KeypadEditorView`: keypad keys have labels and values.
  - `CommandButtonEditor`: tint swatches are labelled.
  - `ContentView`: the main content has an identifier.
  - `MudOutputView`: output and live-tail views have labels.
- `SpeechController` can route speech requests through
  `NSAccessibility.announcementRequested`.
- The native TTS engine supports app speech, VoiceOver routing, recent-line
  replay, vitals, substitutions, prompt policies, and channel mutes.
- The tag cleaner preserves displayable content while stripping leading
  Aardwolf tag markers, and hides machine-data tags such as coordinates.
- Mapper path output spaces out `run` directions for screen-reader readability.
- Channels now use an AppKit/TextKit renderer on macOS, so selection and scroll
  behavior match the main output more closely.

Current gaps:

- The main output is not yet a reliable native VoiceOver live-output stream.
- VoiceOver announcement posting has no reliable public completion callback, so
  a queue must be prototyped and validated rather than assumed.
- Output review is not designed as a screen-reader workflow.
- Semantic review buffers are only partial.
- HUD, panels, and settings still need an accessibility pass with semantic
  grouping, values, and actions.

## Target Architecture

### 1. Native VoiceOver Output Queue

All lines that reach the visual output should enter a VoiceOver output queue.

Requirements:

- Preserve display order.
- Do not interrupt an utterance already in progress.
- Keep VoiceOver focus on the command input.
- Avoid double-speaking with app-owned TTS.
- Avoid recording or exposing private game text in diagnostics beyond the normal
  local transcript.
- Provide enough instrumentation to prove whether the queue is keeping up,
  falling behind, or being skipped by VoiceOver.

Open technical question:

`NSAccessibility.announcementRequested` supports priorities, but does not expose
a dependable public "utterance finished" callback. We need a prototype to decide
whether queued native VoiceOver output can be made reliable. If it cannot, the
fallback is either a hybrid with app-owned speech or a VoiceOver-readable review
surface that users drive directly.

### 2. Output Review Mode

Live play keeps focus in the command input. Review mode is an explicit recovery
and navigation action for missed output.

Requirements:

- Switch between command input and output review with a configurable key path.
- Navigate by line, word, and character.
- Select and copy multiple lines.
- Navigate and activate links from the keyboard.
- Jump to start and latest output with spoken confirmation.
- Return to command input when the user types printable text from output review.
- Support braille by exposing stable text/cursor/selection state through
  VoiceOver.

Reference shape:

Mudlet's screen-reader work uses a caret mode, link navigation, focus redirection
back to the command line, and announcements for buffer/link navigation. Proteles
should follow the interaction shape where it fits macOS conventions.

### 3. Semantic Review Buffers

Screen-reader MUD users often need categorized review, not only a single flat
scrollback. The Aardwolf non-visual MUSHclient package treats review buffers as
central, not decorative.

Candidate buffers:

- All recent output.
- Tells.
- Says.
- Channels.
- URLs.
- Quests.
- Combat / kill summary.
- Group.
- Repop.
- Command captures.
- Vitals.

Reference behaviors to transcribe before designing from scratch:

- Hotkeys for recent messages and category movement.
- Copy current message to clipboard.
- Extract and open URLs.
- Capture the output of a command into a review buffer.
- Route GMCP channel messages into categories.

### 4. Tagged Output Contracts

Do not turn on additional Aardwolf tags until each tag family has a presentation
contract.

For each tag family, define:

- Whether the raw tag is stripped from main output.
- Which review buffer receives the content.
- Whether it feeds Channels or another panel.
- Whether it should be spoken live.
- Whether it changes app state.
- How it is tested against live recordings.

Near-term tag candidates:

- `CHANNELS`
- `TELLS`
- `SAYS`
- `SCORE`
- `EQUIP`
- `INV`
- Later: `WHERE`, `REPOP`, `EDITORS`, and command-specific tags.

### 5. Server-Setting Helper

Server settings are secondary. They can improve the stream, but they are not the
spine of accessibility.

If Proteles later ships a `screenreader` helper, it must be explicit and
reversible:

- Do not auto-detect or auto-enable it.
- Do not silently choose `blindmode 1` vs `2`.
- Use `spamreduce save` before applying defaults.
- Track or restore tag choices where possible.
- Explain every server-side preference changed.
- Provide `screenreader status` and `screenreader restore`.

Possible helper actions:

- Suggest or apply `config automap off`.
- Suggest or apply `config maprun off`.
- Suggest or apply selected tags.
- Suggest or apply `spamreduce` options.
- Suggest or apply `brief 1`.
- Suggest or apply tell queueing.

### 6. UI Accessibility Cleanup

This is necessary, but not the first milestone.

Requirements:

- Audit all Settings panes, Scripts, Plugins, panels, hotbar, Help, status/HUD,
  map, channels, and command buttons.
- Prefer semantic grouping for compound controls.
- Expose useful labels, values, hints, and actions.
- Hide purely decorative pieces from assistive technology.
- Add automated accessibility smoke coverage where feasible.

Concrete example:

The vitals/HUD area should expose meaningful elements such as "Health,
4872 of 7228, 67 percent" rather than many separate shapes and labels.

### 7. App-Owned TTS

App-owned TTS remains useful:

- For users who prefer a dedicated app voice.
- As an emergency fallback if native VoiceOver queueing cannot be made reliable.
- For explicit commands such as `tts vitals`, `tts last`, and plugin/script
  speech.

But it should not be positioned as the primary VI path while full-time VoiceOver
users expect native VoiceOver output.

## Roadmap

### Phase 0: Baseline Recordings

Wait for screen-reader recordings of Proteles and, if available, the Windows
client workflow. Use those to compare expected interaction with current Proteles
behavior before implementing.

### Phase 1: Native VoiceOver Output Queue

Prototype and validate queued native VoiceOver output:

- Displayed lines reach VoiceOver in display order.
- Current speech is not interrupted.
- Focus stays on command input.
- Queue behavior is observable in diagnostics.
- Failure modes are understood before claiming success.

### Phase 2: Output Review Mode

Add the explicit recovery path:

- Keyboard switch between input and output review.
- Text navigation and selection.
- Link navigation and activation.
- Jump to start/latest.
- Typing returns to command input.

### Phase 3: UI Accessibility Cleanup

Audit the app UI:

- Labels, values, roles, hints, and actions.
- Semantic grouping for compound controls.
- Help panel and Settings coverage.
- Automated smoke checks where possible.

### Phase 4: Semantic Review Buffers

Build categorized review on top of tags and GMCP:

- Recent output.
- Channels/tells/says.
- URLs.
- Quests/combat/group/repop.
- Command capture.
- Vitals.

### Phase 5: Optional Server-Setting Helper

Only after output works:

- Explicit opt-in.
- Reversible state.
- No silent privacy decisions.

### Phase 6: Validation Loop

Use screen-reader recordings and issue #9 feedback to iterate. Do not close the
issue until a real screen-reader workflow is validated.

## Acceptance Script

- Use VoiceOver only: login, keep focus in command input, and verify output
  lines are spoken as they arrive.
- Send or replay a burst where line 2 arrives while line 1 is still speaking;
  verify line 1 completes and line 2 starts afterward.
- Confirm typing into the command input works while output is being spoken.
- Stop or pause a large speech backlog, then review missed lines.
- Move, read room name/description/exits, activate an exit link from the
  keyboard, and return to command input by typing.
- Review output by line, word, and character.
- Select and copy multiple output lines.
- Leave the log scrolled up while new output arrives; confirm review position is
  preserved and new output remains discoverable.
- Open the Help panel, search for a help topic, follow related-topic links, and
  read the result without relying only on live streaming.
- During combat or a bursty recording, verify tells/channels remain
  discoverable without drowning the user in routine prompt/combat spam.
- Review semantic buffers: recent lines, channels, tells, URLs, quests, command
  capture, and vitals.
- If braille is in scope, repeat output review and command input with a braille
  display or a recording of that workflow.
- If a server-setting helper is in scope, start from a fresh profile, enable it,
  and verify all server state changes are explained and reversible.

## Sources

- Aardwolf `help vi-index / vi-clients / vi-vidblain / vi-tips / vi-intro /
  vi-summary`, `help blindmode`, `help tags`, `help spamreduce`, `help glance`,
  `help brief`, `help catchtell` (captured live 2026-06-15).
- Aardwolf wiki, Visually Impaired.
- Gaardian accessible maps: http://maps.gaardian.com/vi-index.php
- Aardwolf non-visual MUSHclient package:
  https://fiendish.github.io/aardwolfclientpackage/
- Mudlet Manual, Screen Readers:
  https://wiki.mudlet.org/w/Manual:Screen_Readers
- Apple Developer Forums, macOS VoiceOver announcement skipping:
  https://developer.apple.com/forums/thread/709501
- VIP Mud: https://www.gmagames.com/vipmud.shtml
- Blightmud screen-reader mode: https://forum.audiogames.net/topic/42297/
