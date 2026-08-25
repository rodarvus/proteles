# Burst instrumentation — proposal for review

> **Status: proposal. No code written.** Follows the 2026-08-25 diagnosis where
> three days of performance comparison turned out to be invalid because the
> recordings did not record which build produced them. Items 2 and 3 below are
> the instrumentation that would have made the kill-burst question answerable
> from a single session instead of by inference.
>
> **Constraints taken as given:** must not degrade performance measurably, and
> must be active **only** under `PerformanceProbe.Mode.full` ("Full attribution"
> diagnostics). Item 1 (build provenance) is proposed separately below because
> its cost is one line per session and its absence invalidates everything else.

## 0. Why this is worth doing

The kill-burst investigation needed four things the recordings could not supply:

1. **Which build produced this session** — the one that mattered. Every session
   reports `"version": "0.8.8"` whether it is Release or a 2.30x-slower Debug
   build, so a Release baseline was compared against Debug candidates for three
   days and the difference was attributed to a code change.
2. **The burst as a unit.** Today a 9-line kill burst appears as several
   unrelated `render:` samples. The near-kill figures in this repo were produced
   by *me* bucketing samples "within 30 lines of an experience-gain line" — a
   reconstruction, not a measurement, and one nobody else can reproduce without
   the same script.
3. **Where the time goes inside a burst.** `perf:` phases only emit above a
   50 ms threshold, so a cost of 3 ms on each of 9 lines is invisible — which is
   exactly the shape of a per-line regression.

The through-line: the current instrumentation is built to catch **one slow
thing**, and the failure mode we care about is **many small things at once**.

## 1. Build provenance (recommended, and first)

One line at session start in the transcript:

```
2026-08-25T10:08:00+01:00 NOTE  build: 0.8.8 (56) Release 36da8b19 clean
```

Configuration (`Debug`/`Release`), marketing version, build number, short git
SHA, and whether the tree was dirty at build time. Emitted **always**, not gated
on diagnostics — it is one line per session and it is the datum that makes every
other measurement trustworthy.

### On bumping the build number per change

You asked whether the build number should increase on every change. **I would
not**, and I think the git SHA is the better answer:

- `CFBundleVersion` is what **Sparkle** compares. Dev builds sharing the release
  version line risks a local build outranking a published one — the class of
  problem that already bit `v0.5.0` (build 40 == `v0.4.12`).
- It would churn `project.yml` on every iteration, adding version noise to a git
  history that currently reads cleanly.
- It still would not distinguish Debug from Release, which was the actual gap.

A **git SHA + dirty flag captured at build time** is automatic, precise, needs no
edits, and identifies the tree exactly. Keep build-number bumps for real
releases, as the release flow already does.

## 2. Burst-level probe

**What it measures.** A *burst* is a run of displayed lines arriving without an
intervening idle gap. Rather than sampling per render flush, measure the burst
end to end: from the arrival of its first line to the paint of its last.

Emitted once per burst, under `.full` only:

```
NOTE  burst: 9 lines in 1 packet  arrival→last-paint 764ms  flushes 3  worst-line 121ms
```

**Detection.** A burst begins on the first displayed line after ≥N ms of
inbound quiet and ends when quiet resumes (proposed N = 100 ms, configurable).
No parsing of game text, and no dependence on "an experience-gain line" — the
kill case is simply the most common burst, not a special case. That matters:
the current near-kill bucketing only finds bursts I thought to look for.

**Cost.** Two timestamps and a counter per burst, plus one formatted note per
burst. At the observed rate (~2,800 kills in a six-hour session) this is a few
hundred notes an hour — far below the ~27,800 `text-health` notes a session
already carries. Off entirely outside `.full`.

**What it would have told us.** A single Release session would have shown 437 ms;
a single Debug session 765 ms — directly, as one number per burst, with no
bucketing script and no cross-session inference.

## 3. Phase breakdown inside a burst

**The problem.** `PerformanceProbe.measure(_:thresholdMS:)` emits only when a
phase exceeds its threshold (50 ms in the line path). A per-line cost of a few
milliseconds never emits, and nine of them are exactly what a burst regression
looks like.

**Proposal: accumulate per burst, report once.** While a burst is open, sum each
phase's time instead of threshold-testing it individually. On burst end, emit the
phases that accounted for meaningful time:

```
NOTE  burst-phases: 9 lines 764ms | script-engine 402ms · display 138ms · snd 96ms · semantic 4ms · effects 12ms
```

This makes a regression **self-attributing**: had this existed, "semantic 4 ms"
versus "script-engine 402 ms" would have said immediately that the semantic
layer was not the problem — instead of two rounds of me inferring mechanisms
from code reading.

**Cost.** One accumulator dictionary per open burst, one add per measured phase.
No formatting until the burst ends. Under `.full` only. The measured phases are
already being timed today; this changes what is done with the number, not
whether it is taken.

**Bounding.** Cap accumulated phases per burst (proposed 12) and drop anything
below a floor (proposed 1 ms) so the note stays one line.

## 4. What this does not do

- **No sampling profiler, no signposts in this proposal.** `os_signpost` +
  Instruments remains the right tool for a deep dive; this is for field
  recordings where the user is playing, not attached to Instruments.
- **No game text captured.** Same discipline as the existing probe: phase names,
  durations, counts.
- **Nothing outside `.full`** except the single build line in §1.

## 5. Verification plan

The instrumentation must be shown not to cost anything:

- **A/B the same recording replayed** with `.full` on and `.stallOnly`, comparing
  per-line pipeline time. Pass condition: no measurable difference outside noise
  in `.stallOnly`, and ≤2 % in `.full`.
- **Confirm the burst numbers reproduce the known result**: a Release session
  should report ~437 ms bursts and a Debug session ~765 ms — a check that the new
  probe agrees with the bucketing analysis it replaces, before the bucketing
  script is retired.
- **Release build for live verification**, per CLAUDE.md — the mistake that
  caused this whole detour.

## 6. Open questions for you

1. **Burst gap threshold** — 100 ms proposed. Too low and a slow burst splits in
   two; too high and separate events merge.
2. **Scope**: main output only, or Channels too? Main output alone is simpler and
   covers the reported symptom.
3. **Order**: §1 alone first (tiny, unblocks trustworthy comparison), then §2/§3
   together? That is what I would recommend.
