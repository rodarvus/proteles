# Scripts editor UX rework (issue #4)

> **Status: shipped (feature-complete for 1.0). Historical design doc — kept
> for the rationale and trade-offs.** Issue #4 is **closed**; delivered across
> [`../DECISIONS.md`](../DECISIONS.md) D-51 (the editor rework — Test panel,
> regex validation, enable/duplicate/delete row wins; the **tabbed** layout was
> kept rather than the three-pane master-detail proposed below) and D-105–D-107
> (trigger send-to + highlight, the Commands surface, and the Plugins window).
> The Macros tab landed once MacroEngine shipped.
>
> Original plan deliverable (no code). At the time, the Phase-5 Scripts editor
> worked but the detail forms were a tall, stacked, single-column wall of
> fields, and aliases crammed the command + its actions into one field. Issue
> #4 asked for a clearer layout and a proper command-field + actions-textarea
> split. Files:
> `Sources/MudUI/Scripts/{ScriptsView,ScriptsModel,ScriptEditingSupport}.swift`.

## Problems (from issue #4 + the current views)
1. Detail forms stack *every* field vertically and sequentially — hard to scan,
   no grouping, no sense of "the important bits vs the options".
2. **Aliases**: one cramped field tries to be both the trigger pattern and the
   expansion/actions. They should be a **single-line pattern** + a **multi-line
   actions/script textarea**.
3. Same spirit for triggers (match + a real actions box) and timers
   (interval + actions box).
4. No obvious defaults; the form doesn't guide you to a working script.

## Proposed layout

*(As shipped — D-51: the **tabbed** layout was kept rather than rebuilt as a
three-pane master-detail; the grouped detail forms, defaults, validation, and
Test panel below all landed.)*

**Three-pane master-detail** (matches the macOS norm + our Worlds editor):
`[ type picker: Triggers | Aliases | Timers ] → [ list ] → [ detail ]`.

### Detail form, grouped (not one long stack)
A `Form` with **labelled sections**, the *essential* fields first and *options*
collapsed by default:

- **Triggers**
  - *Match* section: pattern field (monospaced) + a Regex/Plain segmented
    toggle + Ignore-case. A small **"Test"** affordance: paste a sample line,
    see if it matches + the captures (huge usability win, catches regex bugs).
  - *Actions* section: a **multi-line monospaced text editor** for the
    response/script (with a "send to: world / script" picker). Captures legend
    (`%1`, `%0`, named groups) shown inline.
  - *Options* (disclosure, collapsed): sequence, keep-evaluating,
    omit-from-output, enabled, one-shot, group.
- **Aliases** — same shape: single-line *pattern* + multi-line *actions*
  textarea + collapsed options. This is the headline fix from the issue.
- **Timers** — *interval* (h/m/s or "every N seconds") + multi-line *actions* +
  options (enabled, one-shot).

### Cross-cutting improvements
- **Monospaced** pattern/action fields (it's code).
- **Sensible defaults** on "New": enabled, regex on, send-to script for the
  actions box, sequence 100 — so a new item is immediately runnable.
- **Live validation**: invalid regex → inline red hint (we already compile via
  `PatternMatcher`; surface compile errors instead of silently failing — this
  also catches the ICU `{}`/named-group footguns we've hit).
- **Enable/disable toggle** right in the list row (no need to open detail).
- **Duplicate** + **delete with confirm** in the list.
- Keep applying changes live (current behaviour) but add a subtle "saved"
  affordance so the user knows it persisted.

## Data model
No model change required — `TriggerEngine`/`AliasEngine`/`TimerEngine` already
separate pattern from response/script; the editor just needs to *present* them
as pattern + actions instead of merging. The "Test" feature reuses
`PatternMatcher` (pure) — feed a sample line, show match + captures.

## Phases *(all delivered)*
1. **Aliases first** (the explicit ask): pattern field + actions textarea +
   grouped sections + defaults. Ship + get feedback.
2. Apply the same grouped layout to Triggers + Timers; add the collapsed
   Options disclosure.
3. The **"Test" panel** (sample-line → match + captures) for triggers/aliases;
   inline regex validation; list-row enable toggles + duplicate.
4. (Done — MacroEngine landed) added a **Macros** tab here (key-capture +
   action) — see [`MACRO_ENGINE_PLAN.md`](MACRO_ENGINE_PLAN.md).

## Decisions (resolved, D-51)
1. **Layout**: kept the **current tabbed window shape** and fixed the forms
   (the three-pane master-detail was *not* adopted).
2. **"Test" panel**: **built** (`PatternTester`) — it's where users lose the
   most time.
3. Actions-box default send-to: the trigger send-to surface was later refined
   by D-105 (`world`/`execute`/`output`, with `Trigger.script` as its own
   field).

## Effort (as shipped)
Medium, UI-heavy, low-risk (pure SwiftUI over existing value-type engines; no
networking/Lua changes). The "Test" panel was the highest-value extra.
