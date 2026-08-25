# Finishing S0a — proposal **WITHDRAWN**

> **Status: withdrawn 2026-08-25, the day it was written. Do not act on it.**
> It proposed building one of S0a's four remaining items and deferring three.
> That was wrong. **All four are ratified S0 scope and are being built.**
> Tracking: **#82**.

## What it argued, and why it was wrong

The proposal applied a "who consumes this today?" test to items 4–6 of #82
(generalize `NotificationMatcher`, promote `AardwolfTags` to a tag-family router,
re-publish events on the internal bus), found no reader for any of them, and
recommended deferring all three to S0b.

Three things refute it, all of them already written down at the time:

1. **D-118 names all four items as S0's scope**, explicitly:

   > build **S0** (SemanticEvent taxonomy in MudCore; classifier demoted to the
   > built-in Aardwolf vocabulary pack on the *displayed*-line path;
   > **NotificationMatcher generalized as the user rule engine; AardwolfTags
   > promoted to a tag-family router**)

2. **The exit criterion names the consumer the proposal claimed did not exist:**

   > *Exit:* the layer classifies real recorded sessions correctly under test;
   > sound/speech/**notifications** consume it with zero behaviour regressions.

   "Notifications already work" is not "notifications are not a consumer". The
   plan's intent is that they be *rewired* onto the layer — that rewiring is the
   enablement.

3. **§1.5's core argument is that three matchers are one layer** —
   `SoundEventClassifier`, `NotificationMatcher`, `TriggerEngine`. Consolidating
   `NotificationMatcher` is one third of the stated reason the phase exists.
   Deferring it does not trim S0a; it removes its purpose.

## The framing error underneath

**S0–S3 are deliberately a platform/framework enablement gate.** They are built
*ahead* of their consumers on purpose: the frameworks are platform-independent,
and the recordings corpus is what informs their design and proves them correct.
"No consumer yet" is not an argument against an S-phase item — it is a
restatement of what the arc is for.

D-120's derive-from-a-named-consumer rule guards against inventing *speculative
shapes*. It does not license shrinking a ratified phase, which is how this
proposal used it.

## Why this file is kept rather than deleted

Two reasons. A stray "defer three items" proposal found later and acted on would
do real damage, so the withdrawal needs to live where the proposal did. And the
failure is worth keeping visible: it is one instance of a repeated pattern —
generating a plausible local frame and then acting on it as though it were the
agreed frame — which now has a rule against it in CLAUDE.md
(*"Start every stage by quoting the ratified scope"*).

## The one point worth carrying forward

Small, and an implementation note rather than a scope argument: the tag families
the router would enable (`CHANNELS`, `TELLS`, `SAYS`) are all **off** on the live
config, and per `help tags` enabling them **disables the game's scroll/paging**
and changes tell behaviour. So *which* families the router turns on is a decision
to make when item 5 is built — per-feature and reversible, per the policy already
agreed in `AARDWOLF_DATA_FEEDS.md` §3.
