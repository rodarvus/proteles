# S0b — actionable state: scope and checklist

> **Status: approved 2026-10-28 as proposed (D-129): Q1 (a) the promoted
> consumers plus (b) a State inspector, Q2 `{scan}` and `room.wrongdir` out
> (#91), Q3 the order as listed.** Tracking: **#84**.
> This proposes #84's checklist and its order. Each item then gets its own
> proposal (`docs/plans/S0B_ITEM<n>_PROPOSAL.md`) before any code, as S0a
> and S1 did.

## 1. The ratified scope, verbatim

From **D-121**:

> **S0b (#84)** = the actionable-state model, mostly *promotion* of feeds
> that already exist behind single private consumers (`{roomchars}` + the
> `gmkw` keyword port inside `ConsiderFeature`, S&D's target list bridged
> only to Lua, `invdata` parsed by `InventorySerials` with the `type` column
> discarded). Ordering: … S0b before I6 (the lens UI consumes state).

And the entities it names, from the same entry:

> needs **durable entity state** (occupants, exits, floor items,
> inventory/worn/bags/portals, spells and cooldowns, quest targets, vitals)

From **D-123**, on feeds:

> The router (S0a) routes the families that pass the rule and have no GMCP
> equivalent … S0b extends it to the entity families under the same rule.
> Routing enables no family itself (feed ownership stays with the first
> consumer …; a first-use recommendation is #87)

From **#84**, the exit:

> A documented state model with each entity traced to a verified feed,
> consumed by at least one real surface, and validated against recorded
> sessions.

And the standing rule (D-121): **the S-phases are an enablement gate, built
ahead of their consumers**; "no consumer yet" doesn't cut a ratified item.

### 1.1 My reading

- **S0b builds the state model, not lenses.** It is the MudCore model of
  what exists *now* and the handle each thing is acted on by: a targeting
  keyword, an objectid, a direction, a room id, a spell name. Lens UI is I6.
- **The entities are D-121's list,** exactly: occupants, exits, floor items,
  items (carried, worn, bags, portals), spells and cooldowns, quest targets,
  vitals. `LENS_DESIGN.md` §4's twelve add room, channel and combat event:
  - **room** comes with exits;
  - **channel** is already `ChatStore`;
  - **combat event** is S0a.
- **"Mostly promotion"** means each feed's parse moves out of its one
  private consumer into the shared model. That consumer then reads the
  model. This is also what gives each entity its **"real surface"** for the
  exit (Q1): `ConsiderFeature` for occupants, Inventory Serials for items,
  and so on.
- **S0b listens; it doesn't switch feeds on.** Per D-123 and the feeds doc
  §3, whoever consumes a feed owns enabling it. The model fills from
  whatever is on, and says when a feed is absent rather than showing empty
  state as truth.

## 2. What the recordings say (October, 114 sessions)

| Feed | Lines | Sessions | Sent by |
|---|---|---|---|
| `room.info` GMCP | 284,856 | 113 | the game |
| `char.status` GMCP | 380,913 | 114 | the game |
| `{exits}` | 133,604 | 113 | Proteles (`tags exits on`, opt-in) |
| `{roomchars}` | 133,603 | 113 | S&D (`tags roomchars on`) |
| `{roomobjs}` | 133,532 | **59** | nobody in October: your in-game setting |
| `{invmon}` | 154,884 | 113 | your in-game setting |
| `{scan}` | 28,816 | 53 | S&D (`tags scan on`) |
| `{affon}` etc. | 56,999 | 65 | your setting (SPELLUPS) |
| `{spellheaders}` (`slist`) | 1,442 | 110 | community spellup plugins (`slist learned`, `slist hsp`) |
| `invdata` | 664 | 54 | Inventory Serials (`i`), dinv |
| `eqdata` | 11 | 5 | rare |
| `room.wrongdir` GMCP | 1,291 | 37 | the game |

So the feeds the Tier 1–2 entities need are already flowing in nearly every
session, except `eqdata`, which almost nothing requests, and `{roomobjs}`,
which is on for about half the sessions. That is the "a feature must own its
feed" problem (§5).

## 3. The proposed checklist

In `LENS_DESIGN.md` §5's readiness order, with the model's frame first.
Each item ends with its promoted consumer reading the model, and replay
validation over the corpus.

1. **The state model's frame.**
   - A pure `ActionableState` value in MudCore (`Semantic/State/`), and
     where it is updated: the same `ScriptEngine.process` and GMCP-dispatch
     seams S0a uses, with no new actor hop per line.
   - How a consumer reads it (native plugins and the UI).
   - What "feed absent" looks like for each entity.
   - The corpus replay extended to state: invariants and pins, as S0a
     item 7 did for events.
2. **Occupants.** Lift the `{roomchars}` block parse and `ConsiderKeyword`
   out of `ConsiderFeature`; never offer a `(P)` player as a target.
   `ConsiderFeature` becomes the first consumer.
3. **Room, exits and vitals.** These are references, not new parses:
   `room.info` + `{exits}` + the Mapper's custom exits, and `char.vitals` +
   `char.status` (enemy, enemy %, fighting). The model *names* what
   `GMCPState` and the Mapper already hold; it doesn't copy them.
4. **Items: carried, worn, containers, portals.**
   - Widen the `invdata` row parse to all eight fields (keeping `type`:
     11 container, 20 portal) and parse `eqdata` from the same row shape.
   - Keep the model current from `{invmon}` between full lists.
   - Inventory Serials becomes a consumer.
5. **Spells, skills and cooldowns.** Parse the `slist` block
   (`{spellheaders}`: id, name, attack vs spellup, practiced %, cooldown),
   and track `{recon}`/`{recoff}` and `{sfail}` reasons against it.
6. **Quest targets.** Bridge S&D's target list (`targets_as_json`,
   `target_count`) out of Lua into the model, read-only. S&D stays the
   owner.
7. **Floor items.** `{roomobjs}` is prose with no objectid. `LENS_DESIGN`
   §6 open item 1 says whether `ConsiderKeyword`'s keyword heuristic works
   for objects is **unverified**. This item therefore opens with a
   recordings study, and its design waits on the result.
8. **The documented model.** `docs/STATE_MODEL.md`: each entity, its
   handle, its feed, how it is verified, and its consumer. This is the
   exit's "documented" clause; it grows with each item.

## 4. Open questions

**Q1 — What counts as the "real surface" in the exit?**

- **(a) The promoted consumers.** `ConsiderFeature` reads occupants from
  the model, Inventory Serials reads items, and so on. Each entity that has
  a private consumer today gets that consumer as its surface. Entities that
  have none (spells, quest targets, floor items) are covered by replay
  validation plus (b). **Recommended, with (b).**
- **(b) Also a small macOS State inspector,** under Settings ▸
  Development or as a panel: a read-only view of the live model. Its
  purpose is that *you* can verify each item live, since you can't see a
  model. It is a debugging surface, not a lens.
- **(c) A first lens-shaped surface on macOS** (for example a clickable
  room-occupants list that sends `kill <keyword>`). That is closer to the
  goal, but it decides which lenses ship, which `LENS_DESIGN` §6 leaves to
  you after real play. Not recommended inside S0b.

**Q2 — Adjacent rooms (`{scan}`) and failed moves (`room.wrongdir`).**
Both are in `LENS_DESIGN`'s journey tables, but neither is in D-121's
entity list. Recommended: **leave them out of S0b** and file them as a
follow-up issue. Including them would widen ratified scope without your
say. If you read D-121's "occupants" as covering adjacent rooms' occupants,
`{scan}` joins item 2.

**Q3 — Order.** The order above is `LENS_DESIGN`'s readiness ranking, with
quest targets ahead of floor items because their feed is verified and floor
items need research first. Alternatively, items (4) could go before room,
exits and vitals (3), since 3 is mostly naming what exists. Recommended:
**as listed.** Item 3 is small and settles the model's
reference-not-copy pattern before the bigger parses.

## 5. What does not change, and what is out of scope

- **No feed is switched on by S0b** (D-123). `{roomobjs}` and `eqdata` stay
  whatever your settings and plugins make them. #87 (first-use
  recommendations) owns enabling, and it lands with the first lens phase.
- **No lens UI**, no decision about which lenses ship, no player-authored
  lenses (`LENS_DESIGN` §6, D-122).
- **No new events.** `{invmon}`, `{affon}` and `{recon}` already route
  through S0a where they are events; S0b keeps *state* from the same
  lines without re-classifying them.
- **The Mapper, `GMCPState`, `ChatStore` and S&D keep owning their data.**
  The model references them; it doesn't duplicate them.
- **Display:** nothing about what lines show or hide changes.

## 6. Impact

- **Hot path:** several items parse per-line tag blocks (`{roomchars}` on
  every room look, `{invmon}`), so each item's proposal carries a
  measurement plan before code, per CLAUDE.md: a same-day control build,
  normalised per event. Item 1 sets the pattern: state updates ride the
  existing classification pass, so there is no new hop.
- **Risk:** promoting a parse out of `ConsiderFeature` and Inventory
  Serials touches two shipped features. Each item keeps the feature's tests
  green and is live-checked through that feature.
- **Size:** about eight proposals. Items 1, 2 and 4 are the largest.

## 7. After approval

1. Write #84's checklist from §3 (and the Q2 follow-up issue, if out).
2. Record a D-NN entry for the S0b scope reading (§1.1, Q1–Q3).
3. Start item 1's proposal.
