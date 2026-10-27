# Tag-sourced events are dropped at the gag seam — proposal

> **Status: proposed 2026-10-27, awaiting approval.** Found while
> live-testing S1 step 2 (`docs/plans/S1_ITEM2_PROPOSAL.md` §10). Tracking:
> **#83** (the consumer) and **#82** (the seam it corrects).

## 1. What happened

In `session-20261027-090604` the player ran
`spset affect_off wav channel_on.wav`. Indestructible Aura then wore off
(`{affoff}91`, 09:10:02.972) and was recast, and **no cue played**.

The recording shows why:

```
09:10:02.972Z RECV  {affoff}91
09:10:02.978Z GAG   [script+tag] {affoff}91
```

The line was hidden twice:

- by a **script**: the spellup plugin matches tag lines with
  `omit_from_output="y"`, the standard MUSHclient idiom for machine data;
- by the **tag** display preference ("hide tag lines").

The session publishes semantic effects **only for a line that survives every
gag** (`SessionController+LineProcessing.swift`,
`appendLineWithGenericScripts`). `finishGaggedLine` applies
`disposition.effects` and drops `disposition.semanticEffects`. So the
`affect_off` event was classified, the soundpack produced its cue, and the
session threw the cue away.

**It is not a one-off.** In the eight most recent recordings, every
event-tag line (`{affon}`, `{affoff}`, `{recon}`, `{recoff}`, `{sfail}`,
`{skillgain}`) is gagged `[script+tag]`. That is 1,781 of 1,781 lines. **No
tag-sourced event has ever reached a consumer in live play.** Nobody
noticed because nothing consumed tag events until S1 step 1 (`fde0ef1c`).
The corpus replay calls the classifier directly, without the session's gag
seam, so it could not see it either.

## 2. The two rules that collide, verbatim

**S0a wiring** (`docs/plans/S0A_WIRING_PROPOSAL.md`, Option B, approved),
written before tag routing existed:

> 3. `SessionController` applies them **only when `shouldDisplay` is true**,
>    and discards them otherwise.

Its purpose is in the same document and in **D-118**: the classifier runs
"on the *displayed*-line path", because "cues fire on raw pre-gag lines
while speech reads displayed lines". That is a rule about **prose**:
whether the player saw `You raise a level!`.

**S0a item 5** (`docs/plans/S0A_ITEM5_PROPOSAL.md` §1.1, *confirmed
2026-09-07*):

> routing decides what the *layer* learns from a tagged line; display
> decides what the *player* sees, exactly as today. The two are independent
> — a hidden `{affoff}58` still yields its event

and §3.3: "Routing is independent of the 'clean tag markers' preference: a
hidden `{affoff}58` line still yields its event."

Item 5's implementation note (§7) says it kept the "same gag-then-apply
rule". That is where the two met: the classifier does yield the event, as
promised, but the seam then discards it. The tests for item 5 run at engine
level, above the seam, so they passed.

## 3. Proposal

**Option A: the gag rule applies to prose-sourced events only.**
Tag-sourced events publish whether or not their line is displayed.

- `ScriptEngine.process` already collects semantic effects in one pass.
  It splits them by the event's `source`:
  - effects from `.pattern` events stay in `semanticEffects`, applied only
    when the line is displayed, exactly as today;
  - effects from `.tag` events go in a new `structuralEffects` on the
    disposition.
- `SessionController` applies `structuralEffects` on **both** paths:
  - in `finishDisplayedLine`, together with the other effects;
  - in `finishGaggedLine`, beside `disposition.effects`.
- GMCP events are unaffected; they never pass through the line seam.

The rule this records, as a decision (proposed **D-128**):

> **Structural events publish regardless of display; prose events publish
> only from displayed lines.** A tag line is machine data whose hiding is
> the norm (the tag preference, and plugins' `omit_from_output`); whether
> the player saw it says nothing about whether the event happened. A prose
> line's display is what D-118's displayed-path rule protects. Reconciles
> the S0a wiring rule with S0a item 5 §1.1.

## 4. Options considered

- **A. Exempt tag-sourced events from the gag rule.** Proposed. It keeps
  both confirmed rules, each for the kind of line it was written for. The
  change is two fields and two call sites.
- **B. Exempt only the tag display gag; a script gag still drops.** It
  respects a plugin's `omit_from_output` literally, but that idiom means
  "don't show this machine data", not "this didn't happen". Every event-tag
  line in the recordings is script-gagged too, so under B the cue still
  never plays. Rejected.
- **C. Classify tag lines at a separate seam, before the gags, in the
  session.** Same result as A, but a second classification point, against
  D-118's single one, and possibly an actor hop per tag line: the trap the
  wiring proposal measured. Rejected.
- **D. Leave it, and document that tag events cannot carry cues.** That
  contradicts the confirmed item 5 rule and makes step 2's open vocabulary
  half-true. Rejected.

## 5. What does not change

- Prose events from a gagged line are still dropped. The existing test
  `gaggedLineProducesNoCue` must still pass.
- Display: the tag hide/strip behaviour, the preference, and plugins'
  gags.
- The classifier, its rules, the vocabulary, the opt-in gate, GMCP routing.
- Speech: it reads displayed text, not events (D-126).

## 6. Tests

- **Reproduce first (fails today):** a session-level test in
  `AudioEndToEndTests`. Unmute the soundpack, run
  `spset affect_off wav channel_on.wav`, turn the tag-line hide preference
  on, add a gagging trigger on `^\{affoff\}`, then feed `{affoff}91`. One
  `channel_on.wav` cue must come out on `soundCues`.
- The same with only the tag hide, and with only the script gag.
- **Unchanged:** a gagged `You raise a level!` still produces no cue.
- An engine-level test: an `{affoff}` line puts its effects in
  `structuralEffects` and a level-up line puts its effects in
  `semanticEffects`.

## 7. Hot path and impact

- **Per-line cost:** classification already runs. The change only
  partitions the effects of lines that produced events, and applies tag
  effects on the gagged path. The gagged path is where every tag line goes
  (§1), so this adds effect application only for tag lines whose event has
  a consumer that returns effects (today: a cue set by the player). With no
  cue configured, nothing is applied. **Proposed: no A/B.** It moves no work
  ahead of the opt-in guard and adds no actor hop. Say if you want one.
- **Behaviour:** tag events reach consumers for the first time. With an
  unedited cue map nothing is audible, because tag events have no default
  sound. With a cue set, it plays on every matching tag line, including
  spellups recast in bulk: a spellup cast after a death can produce a dozen
  `{affon}` lines in a second. Step 4 (playback discipline) is where rate
  limits arrive; until then, a cue on `affect_on` can stack.
- **Files:** `ScriptEngine+TriggerEffects.swift` (the disposition),
  `ScriptEngine+Process.swift`, `SessionController+LineProcessing.swift`,
  tests, and the D-128 entry.
