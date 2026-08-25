# S0a item 4 — `NotificationMatcher` as the user rule engine

> **Status: design proposal. No code written.** Tracking: **#82**.

## 1. The ratified scope, verbatim

From **D-118**:

> build **S0** (SemanticEvent taxonomy in MudCore; classifier demoted to the
> built-in Aardwolf vocabulary pack on the *displayed*-line path;
> **`NotificationMatcher` generalized as the user rule engine**; `AardwolfTags`
> promoted to a tag-family router)

From `IOS_PORT_PLAN.md` §4a:

> `NotificationMatcher` generalized as the user-extensible rule engine **feeding
> the same events**

Exit criterion for the phase:

> the layer classifies real recorded sessions correctly under test;
> sound/speech/**notifications** consume it with zero behaviour regressions.

**My reading, for you to confirm or correct:** today there are two independent
matchers over the same text — the built-in vocabulary (`SoundEventClassifier`,
now behind `SemanticClassifier`) and the user's rules (`NotificationMatcher`).
Item 4 makes the second one *emit `SemanticEvent`s too*, so that a user-authored
rule is a first-class event source alongside the built-in pack, and notifications
become a **consumer of the layer** rather than a parallel path. That is one of
the three matchers §1.5 says are secretly one layer.

This is enablement, built ahead of most of its readers on purpose — that is what
the S-arc is for.

## 2. What exists today

| Piece | Role |
|---|---|
| `NotificationRule` | User rule: `Trigger` (`.keyword`, `.channel`, `.hpBelow`, `.questReady`), `regex`, `sound`, title/body templates |
| `NotificationMatcher` | Holds rules + the built-in tells/mention behaviour; returns `ProtelesNotification?` |
| `NotificationCoalescer` | Collapses duplicate banners in a burst |
| `SessionController+Notifications` | Five call sites: chat line, output line, HP vitals, quest-ready, settings push |

Four trigger kinds across three feeds: **displayed lines** (`.keyword`), **chat
lines** (`.channel`), **GMCP vitals** (`.hpBelow`), **S&D quest state**
(`.questReady`).

## 3. The design

### 3.1 Rules emit events; notifications are built from events

`NotificationMatcher` gains an event-producing entry point beside its existing
notification-producing one:

```
func events(forDisplayed line: String) -> [SemanticEvent]
func events(for chatLine: ChatLine, characterName: String?) -> [SemanticEvent]
func events(forVitals …) -> [SemanticEvent]
```

Each matched rule yields a `SemanticEvent` with:

- `category` — from the trigger kind (see §3.2)
- `name` — `"rule.<uuid>"`, stable across a session and distinct from the
  built-in vocabulary's names
- `source` — `.pattern(rule: "user.<label>")` for keyword rules;
  `.gmcp(package: "char.vitals")` for `.hpBelow`; `.tag(family:)` where a future
  rule keys off a tag. **The tiering is not cosmetic**: a keyword rule is exactly
  as fragile as any other prose match, and the event should say so.
- `payload` — the captured text, channel, sender, HP percent: what the existing
  title/body templates already interpolate.

`ProtelesNotification` is then built *from* the event rather than in parallel
with it. The template rendering, coalescing and focus-suppression stay exactly
where they are.

### 3.2 Category mapping

| Trigger | Category | Why |
|---|---|---|
| `.keyword` | `.system` | A user watching for arbitrary text; no better claim |
| `.channel` | `.communication` | A person said something |
| `.hpBelow` | `.combat` | Vitals crossing a threshold is a fight signal |
| `.questReady` | `.world` | The world offering something |

Open to correction — `.keyword` → `.system` is the weakest of the four, since a
keyword rule could be watching for anything. The alternative is a
`.userDefined` category, which I've avoided because it describes the *rule's
origin* rather than what happened, and `source` already records origin.

### 3.3 Where it runs — and the performance discipline

At the **same seam** as the built-in classification, inside
`ScriptEngine.process`, behind the same opt-in guard that made Option B free.
Concretely: no new actor hop, and the existing `hasOutputRules` / `hasHPRules`
short-circuits stay **ahead** of any matching work, exactly as
`wantsSemanticEvents` sits ahead of the 48 regexes.

The measurement plan is the one already agreed, since this touches the same hot
path: **near-kill paint p50 within noise of 437 ms**, from a Release session
recording, plus the per-burst phase breakdown showing no new phase of
consequence.

### 3.4 Behaviour: unchanged

This is a refactor of *how* a notification is derived, not *whether*. Same rules,
same banners, same coalescing, same suppression. The exit criterion says "with
zero behaviour regressions" and that is the bar.

## 4. What I am explicitly not doing

- **Not** touching `TriggerEngine` — the third matcher. It is GUI-authored and
  belongs with S1's trigger `sound` action, which is where a named consumer
  appears for it.
- **Not** adding new trigger kinds. Tempting (a rule keyed on a semantic
  *category* — "notify me on any `.combat` event") and genuinely the direction
  this unlocks, but it is new user-facing surface with no request behind it.
  Flagging it as a follow-up rather than smuggling it in.
- **Not** changing the persisted `NotificationRule` shape, so existing user rules
  keep working untouched.

## 5. Tests

- **Parity, per trigger kind**: for the same input, the event-derived
  notification equals what the current path produces — the anti-regression net.
- **Events carry correct source tiering**: a keyword rule is `.pattern`, an
  `.hpBelow` rule is `.gmcp`.
- **Transcript-driven**: run a real recording through a rule set and assert the
  event stream, per `AARDWOLF_DATA_FEEDS.md` §8 (fixtures from the corpus, never
  hand-written).
- **Guard order**: with no enabled rules, no matching work happens — the
  regression class that bit the first wiring attempt.

## 6. What I need from you

1. **Does §1's reading of the scope match yours?** That is the check the new
   CLAUDE.md rule exists to force, and it matters more than the rest of this
   document.
2. **`.keyword` → `.system`**, or is a `.userDefined` category worth the eighth
   case?
3. **Confirm behaviour-neutral is the bar** — no new trigger kinds, no new UI, in
   this item.
