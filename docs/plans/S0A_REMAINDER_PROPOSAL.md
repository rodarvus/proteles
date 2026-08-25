# Finishing S0a — proposal for review

> **Status: proposal. No code written.** Tracking: **#82**.
>
> Three of the seven items on #82 are done. This argues that **one** of the
> remaining four should be built now and the other three deferred to S0b (#84),
> because they have no consumer — the same condition that produced the wiring
> detour, arriving again in a different costume.

## 1. Where S0a actually stands

| # | Item | State |
|---|---|---|
| 1 | `SemanticEvent` taxonomy | **done** — `3b66acd0` |
| 2 | Single classification point | **done** — `43bd3dcd` (Option B) |
| 3 | `SoundEventClassifier` demoted to vocabulary pack | **done** — `3b66acd0` |
| 4 | `NotificationMatcher` generalized as the user rule engine | open |
| 5 | `AardwolfTags` promoted to tag-family router | open |
| 6 | Events re-published on the internal bus | open |
| 7 | Transcript-driven replay tests | open |

Item 2 is validated in production: near-kill paint 468 ms against a 437 ms
baseline, and `semantic` does not appear in any burst's phase breakdown — it
falls below the 1 ms floor. The layer works and costs nothing measurable.

## 2. The consumer test, applied honestly

D-120 requires abstractions be derived from a **named consumer**. Ignoring that
is what produced a "fix" for a bug that had never occurred once in 593,246
gagged lines. So, for each remaining item — who reads it *today*?

**Item 4 — generalize `NotificationMatcher`.** Consumer: **none.** Notifications
work. The generalization's value is that a user-authored rule could feed sound or
a lens as well as a notification — but there is no `sound` action on triggers yet
(that is S1/#83) and no lens (S0b/#84). Building it now means designing the rule
model against imagined readers.

**Item 5 — `AardwolfTags` as a tag-family router.** Consumer: **S0b, not S0a.**
The tag families that matter are the entity feeds — `{roomchars}` → occupants,
`{roomobjs}` → floor items, `{invdata}` → items. Those are *state*, which is
explicitly S0b's half of the split. The families S0a would route
(`CHANNELS`/`TELLS`/`SAYS`) are **all off** on the live config, and per
`help tags` enabling them **disables the game's scroll/paging** and changes tell
behaviour. So item 5 costs the player something real, to feed a reader that does
not exist.

**Item 6 — re-publish events on the internal bus.** Consumer: **none.** No
plugin or script asks for semantic events. The `BroadcastPlugin(100)` lesson it
cites is about *ordering* when there are subscribers; there are none.

**Item 7 — transcript-driven replay tests.** Consumer: **us, now.** This is the
exit criterion — "classifies real recorded sessions correctly under test" — and
the corpus (51 recordings, 1.8 GB) exists. It is also the only remaining item
that would have caught a real defect.

## 3. Recommendation

**Build item 7. Move items 4, 5 and 6 to #84 (S0b), to be built when a lens
actually reads them.**

That closes S0a on its exit criterion — the layer classifies real sessions
correctly, and sound consumes it with no behaviour regression — without
speculatively designing three abstractions against imagined readers.

Concretely for item 7:

- **Replay a full recording** through `SemanticClassifier` and assert the event
  stream: total counts per category, and specific known events at known lines.
- **Fixture from the corpus**, not hand-written, per `AARDWOLF_DATA_FEEDS.md` §8.
  A trimmed excerpt checked into `Tests/MudCoreTests/Fixtures/` so CI does not
  depend on `~/Documents`.
- **Cover the ordering hazard at scale**: the `keep_evaluating="n"` trio is
  already unit-tested on two lines; a replay proves it across thousands.
- **Guard against classification drift**: if a future vocabulary change starts
  firing `info` where it fired `double_end`, the replay counts move and the test
  fails.

Bounded: one fixture, one suite, no production code.

## 4. What this leaves S0a as

A taxonomy, a classifier, one classification point, sound reading it, and a
replay test proving it against real sessions. That is a complete, honest phase.
The parts that make the layer *extensible* — user rules, tag routing, a
subscriber bus — arrive with the thing that needs them extended.

## 5. If you disagree

The counter-argument is real and worth stating: building 4/5/6 now means S0b
starts with the substrate finished, and there is a cost to revisiting the same
files twice. I weigh that lower because the lens paper design (`LENS_DESIGN.md`)
found the entity feeds are mostly *promotion of existing parsers*, so S0b will be
touching those files regardless — and because the alternative is designing a rule
model and a router shape with nothing to validate them against.

## 6. What I need from you

1. **Item 7 only**, or all four?
2. If item 7 only: should 4/5/6 move onto **#84** as checklist items, or become
   their own issue?
