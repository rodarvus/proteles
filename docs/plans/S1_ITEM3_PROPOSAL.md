# S1 step 3 — cues carry their event; playback discipline

> **Status: approved 2026-10-27; implemented and live-checked, with the
> rate limit changed after the first live test to "a run of repeats plays
> once" (§8).** Tracking: **#83**.
> Order of work: `IOS_PORT_PLAN.md` §4a S1 (v0.5).

## 1. The ratified scope, verbatim

From **#83**:

> - [ ] Playback discipline: concurrency cap, rate limits

From **D-127** (1):

> **Event routing is generic; sound is one consumer.** … only the cue map,
> mixer, playback discipline and Audio settings are sound-side.

And from the plan's §2.5 and #83's "Why":

> Mixing *policy* lives in MudCore (macOS has no `AVAudioSession`, so the
> platform audio layer must stay thin anyway); iOS adds only
> session-category citizenship.

### 1.1 My reading

Two pieces of work:

- **A cue knows which event it is.** Discipline needs this to tell "the same
  event again" from "a different event".
- **The player never stacks or floods.** That means a cap on sounds playing
  at once, and a rate limit.

The policy is a pure value in MudCore. Each platform's player only reports
what is playing and does what the policy says. No new settings in this
step: the limits are fixed defaults, set from the recordings, and exposing
them belongs to the Settings step (#83 task 5), if anywhere.

## 2. What the recordings say

I replayed October's 111 recordings and timed every cue an unmuted
soundpack would play, with the default map and again with sounds set on
the six tag events (`affect_on` and the rest, possible since D-128).
Overlap was simulated with the real lengths of the player's own sound
files (67 files, mean 0.83 s, longest 2.35 s).

| | Default map | With tag-event sounds |
|---|---|---|
| Cues | 49,528 | 170,172 |
| Cues per active second, p99 | 2 | 8 |
| Densest second | 16 | 75 |
| Most sounds playing at once | 16 | 74 |
| Same event again within 0.25 s | 1,001 | 34,735 |

**The bursts are one event repeated.** The worst five seconds of the month
are 16 `bonus_item` cues from one packet (looting a stack), and four
seconds of 10 `market` cues. Different events rarely pile up.

Simulating a **minimum gap between repeats of the same event**, with a
5-sound cap:

| Gap | Default: dropped / densest second / most at once | Tag sounds: dropped / densest / most at once | Cue started with 5 already playing |
|---|---|---|---|
| none | 0 / 16 / 16 | 0 / 75 / 74 | 56 / 6,144 |
| **0.25 s** | **1,001 (2.0 %) / 4 / 4** | **34,735 / 7 / 5** | **0 / 0** |
| 0.5 s | 1,190 / 3 / 3 | 38,159 / 5 / 5 | 0 / 0 |
| 1.0 s | 1,444 / 3 / 3 | 43,851 / 5 / 5 | 0 / 0 |

A 0.25 s gap alone removes every overlap above 4, or above 5 with tag
sounds on. It drops 2 % of default cues, all of them same-event repeats
inside a quarter second, which a listener hears as one sound anyway. A
longer gap starts eating repeats a player can tell apart: a second
`bonus_item` loot half a second later is a real second event.

**MUSHclient's own limit:** in the soundpack's mode (`PlaySound(0, …)`) it
plays at most **5** sounds at once. A sixth takes slot 1, stopping what was
playing there (`methods_sounds.cpp`, `MAX_SOUND_BUFFERS / 2`). It has no
rate limit.

## 3. What changes

**MudCore**

- **`SoundCue` gains `event: String?`.** The soundpack sets it.
  `PlaySound` from Lua (compat-shim plugins, S&D) leaves it `nil`.
- **`ScriptEffect.playSound` carries a `SoundCue`** instead of three loose
  values, so the event travels with it. Nine match sites change: two in
  sources, the rest in tests.
- **New `CueGovernor`**, a pure value type that owns the policy:
  - `admit(_ cue:, at: time) -> Decision`, where the decision is `.play`,
    `.playReplacing(id)` or `.drop`.
  - `finished(id)` for the player to report when a sound ends.
  - **Rate limit:** the same key within **0.25 s** is dropped. The key is
    the cue's event, or its file when there is no event, so a Lua plugin
    repeating one file is limited too. (As built, the gap is measured from
    the key's last *arrival*, not its last play: see §8.)
  - **Concurrency cap: 5** (MUSHclient's number). At the cap, the oldest
    playing sound is stopped and the new one plays: the newest cue is the
    current news, and this is the closest equivalent of MUSHclient's
    slot-1 takeover. By §2, it should not trigger in normal play; it is
    the backstop.
  - Time is passed in, so tests are deterministic.

**App (`CuePlayerController`)**

- Owns one `CueGovernor`, asks it before each play, stops the player it
  names on `.playReplacing`, and reports `finished` from the existing
  `audioPlayerDidFinishPlaying`.
- The system-alert fallback counts as playing too, with the alert's
  length unknown, so its slot is freed after 1 s.
- A dropped cue writes an `os_log` debug line only. It doesn't go in the
  transcript, because the player lives app-side, away from the
  session's recorder.

## 4. Options considered

- **A. Per-event gap plus a cap, in a MudCore governor the player owns.
  Proposed.** It needs no extra per-line work, sits where playback state
  is known, and keeps the iOS player thin.
- **B. Also a global rate limit** (N cues a second across all events). #83
  says "rate limits", plural. But per §2, with the per-event gap the
  densest second is 4, or 7 with tag sounds, and the cap already bounds
  what is audible at once. A global limit would only drop *different*
  events, which are the ones a player most wants to hear. Not proposed;
  the per-event gap is the rate limit. Say if you read #83 as requiring
  both.
- **C. Discipline in `SessionController`.** The session has the
  transcript, so drops would be visible in recordings, but it does not
  know when a sound ends, so it can't enforce a concurrency cap. A split
  (rate limit in the session, cap in the player) puts one policy in two
  places. Rejected.
- **D. Queue cues instead of dropping them.** A late cue is wrong
  information ("a tell arrived" two seconds after it did). Rejected.

## 5. What does not change

- **Which cues fire, and their files, volumes and pans.** The cue map,
  the corpus pins and the soundpack's mute are untouched.
- **Notification banners and their system sounds** (step 5).
- **Speech.**
- **Settings:** no new user settings.

## 6. Tests

- **`CueGovernor`:**
  - the same event at 0.0 and 0.2 s gives play, drop; at 0.3 s it plays
    again;
  - different events inside 0.25 s both play;
  - an event-less cue is limited by its file;
  - the sixth concurrent cue replaces the oldest, and `finished` frees a
    slot;
  - a gap of exactly 0.25 s plays.
- **Soundpack:** cues carry their event name; a Lua `PlaySound` cue
  carries none.
- **Session:** `.playSound` still yields one `SoundCue` per effect,
  gated by the mute as today.
- **Replay:** the corpus cue pins are unchanged. The governor runs in the
  player, after the pins are counted.

## 7. Hot path and impact

- **Per cue, not per line:** a dictionary read, and a scan of at most 5
  playing entries. No A/B proposed.
- **Behaviour:** in default play, about 2 % of cues disappear, all of
  them a repeat of the same event inside a quarter second, such as a
  stack of `bonus_item` loots playing once instead of 16 times on top of
  each other. With sounds on tag events, a spellup recast plays each
  distinct event once per quarter second instead of a dozen overlapping
  copies.
- **The user-visible risk** is a player who *wants* every repeat, for
  example counting loot by ear. The 0.25 s gap keeps repeats that are
  actually apart.
- **Files:** `SoundCue.swift`, a new `CueGovernor.swift`,
  `ScriptTypes.swift`, `LuaRuntime+HostDispatch.swift`, `Soundpack.swift`,
  `SessionController+Scripting.swift`, `CuePlayerController.swift`
  (app), and tests.

## 8. Implementation notes (2026-10-27)

- **Inline `!!SOUND` cues** carry the event `remote_sound`, the event that
  gates them, so two inline sounds inside 0.25 s collapse into one. The
  settings-change confirmation (`channel_on.wav`) carries no event and is
  limited by its file.
- **The player's bookkeeping.** `AVAudioPlayer.stop()` sends no finish
  callback, so a replaced cue is removed from the player's tables when it
  is stopped. A system-alert fallback (`NSSound`) holds its slot for 1 s.
  A cue whose file turns out to be unplayable never takes a slot.
- **Rate-limit clock:** `ProcessInfo.systemUptime`, which is monotonic.
- **Tests:** `CueGovernorTests` has 7 tests: gap, exact gap, a run of
  repeats playing once, different events, event-less cues keyed by file,
  cap replacing the oldest with `finished` freeing a slot, and repeated or
  unknown `finished`. `SoundpackPluginTests` checks the event on soundpack,
  confirmation and inline cues; `PlaySoundShimTests` checks that a Lua
  `PlaySound` cue names no event.
  `runPlaysOnce` replays the recorded recast's timing: 70 arrivals 0.113 s
  apart play once, and a full-gap pause plays again.

### 8.1 The rate limit, after the first live test

**As approved, "one cue per gap"** (the gap measured from the last cue
that *played*) held for short bursts: three identical `spfire`s played
once. A spellup recast with a sound on `affect_on` still sounded like
every spell. The recording (`session-20261027-122534`) has 64 `{affon}`
lines over 7.88 s, a median 0.113 s apart, so a quarter-second gap from
the last play let 23 of them through.

**Changed to "a run of repeats plays once":** every arrival of a key
restarts its gap, whether it played or not, so a run plays at its start
and not again until it pauses for 0.25 s. The recorded recast plays 3
cues under this rule instead of 23.

**October re-simulated** (112 sessions, the real governor, the player's
file lengths):

| | Default map | With tag-event sounds |
|---|---|---|
| Cues | 50,020 | 171,076 |
| Dropped | 1,047 (2.1 %) | 39,289 (23 %) |
| Densest second | 4 | 6 |
| Most at once | 4 | 5 |
| Cap triggered | never | never |

The default map barely moves (2.1 % against 2.0 %): its bursts are
short, and both rules treat them alike. Most dropped by default:
`market` 440, `quest_target_found` 272, `clantalk` 117, `say` 104.
Channel events share one gap per channel, so two messages on one
channel inside a quarter second play one cue.

**Live check** (`session-20261027-143101`): a full recast played twice.
The recording shows why: the server paused 0.78 s mid-recast (spells 4
to 104, then a pause, then 112 to 444, never more than 0.22 s apart), so
two runs, one cue each, as designed.

Left open, not built: staggering *different* events that arrive together
(they play back to back), and writing cue plays and drops into the
transcript (the player is app-side, away from the recorder).
