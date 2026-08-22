# Lenses — the paper design

> **Status: paper design, no code.** D-120 requires that S0's taxonomy be derived
> from a named consumer rather than invented, and lenses are that consumer. This
> document works backwards from the user journeys to the entities and actions
> they need, then maps each to a **verified** feed from
> [AARDWOLF_DATA_FEEDS.md](../AARDWOLF_DATA_FEEDS.md). Which lenses actually
> ship is deliberately still open — the purpose here is to size the substrate,
> not to commit a UI.
>
> Tracking: **#84** (S0b, actionable state) and **#82** (S0a, events).

## 1. What a lens is

Not a display filter. **An interaction surface**: the goal is to let a player act
meaningfully *without typing full commands and without scrolling the main window
back*. Interaction can be touch, voice, buttons, menus or shortcuts — the lens is
the model behind them, not any one of those.

Consequences that shape everything below:

- Journeys are **verb-shaped**. "Attack a mob", not "show combat text".
- A lens therefore needs **durable entity state** — what exists *now* and what can
  be done to it — which is a different shape from S0a's ephemeral events.
- The unfiltered stream stays one gesture away and is never destroyed. Lenses are
  *views over* the scrollback, not replacements for it.

## 2. The action side is nearly free

Decomposing all five journeys, **every action reduces to sending a command
string** — `kill <keyword>`, `get <item>`, `mapper goto <id>`, `cast <spell>
<target>`, `nx`, `remove <item>`. `SessionController.send` already exists and is
the only machinery required.

There is one wrinkle worth stating early: an action needs a **handle**, not a
display name. `kill "A Champion of the Order of Light"` does not work. Producing
handles is the real work, and §4 shows it is largely already solved.

So: **the entity/state side is the whole problem.** That is why the S0 split put
it in its own phase.

## 3. Journey decomposition

Verified feed column uses AARDWOLF_DATA_FEEDS.md §4/§6. "Trapped" = parsed today
but private to one consumer.

### Navigating

| Entity | Actions | Feed | Status |
|---|---|---|---|
| Exit | walk | `{exits}`, `room.info` | available |
| Custom exit | use | Mapper DB (`Mapper+CustomExits`) | available |
| Room (arbitrary) | goto | Mapper DB → `mapper goto <id>` | available |
| Occupant (mob) | target, consider | `{roomchars}` + `ConsiderKeyword` | **trapped** in `ConsiderFeature` |
| Floor item | get, open, get-from | `{roomobjs}` | **unparsed** |
| Portal | activate | `invdata` type 20; `Mapper+Portals` | **partial** — see §4a |
| Failed move | (feedback) | `room.wrongdir` GMCP | **unhandled** |

### Quests / campaigns / global quests

| Entity | Actions | Feed | Status |
|---|---|---|---|
| Quest target | attack next, skip | S&D `targets_as_json` / `target_count` | **trapped** in Lua |
| Quest state | observe | `comm.quest` GMCP | available |
| S&D command (`go`, `nx`, `qw`, …) | invoke | — (send a string) | free |

### Combat

| Entity | Actions | Feed | Status |
|---|---|---|---|
| Current enemy | observe | `char.status.enemy` + `enemypct` | available |
| Combat state | observe | `char.status.state` (8 = fighting) | available |
| Occupant (mob) | attack, aim | `{roomchars}` + keyword | **trapped** |
| Adjacent occupant | scout, move-to | `{scan}` (direction-grouped, flagged) | **unparsed**, S&D enables it |
| Exit | flee/retreat | `{exits}` | available |
| Spell / skill | cast | `slist` (id, name, **attack vs spellup**, practiced %, cooldown) | **unused** |
| Cast failure | pick another | `{sfail}` — immune/already-up/no-mana/cooldown | **unused** |
| Cooldown | wait / pick another | `{recon}` / `{recoff}` + `slist recoveries` | **unused** |
| Vitals | observe | `char.vitals` | available |
| Combat flow | observe | **event-shaped — S0a**; verb ladder ordinal (§2 of feeds doc) | S0a |

### Inventory

| Entity | Actions | Feed | Status |
|---|---|---|---|
| Worn item | remove, switch | `eqdata` | **unparsed** |
| Carried item | wear, drop, give | `invdata` | **partial** — §4a |
| Container | list contents | `invdata <objectid>`, type 11 | **partial** — `type` discarded, §4a |
| Portal | activate | `invdata` filtered to type 20 | **partial** — `type` discarded, §4a |
| Inventory change | observe | `{invmon}` | **unparsed** |

### Comms

| Entity | Actions | Feed | Status |
|---|---|---|---|
| Channel | filter, mute | `comm.channel` + `ChatStore` | available |
| Channel message | observe | `comm.channel` | available |
| Tell | observe, reply | `comm.channel`; `TELLS` tag **off** | available (tag optional) |

## 4. The entity inventory

Twelve entities cover every journey. That is the taxonomy's real size.

| # | Entity | Handle for actions | Handle source |
|---|---|---|---|
| 1 | Exit | direction word | `{exits}` |
| 2 | Room | room id | Mapper DB |
| 3 | Occupant | **targeting keyword** | `ConsiderKeyword` (S&D `gmkw` port) |
| 4 | Floor item | item keyword | from `{roomobjs}` prose — *needs derivation* |
| 5 | Carried / worn item | **objectid** | `invdata` / `eqdata` field 1 |
| 6 | Container | objectid | `invdata` type 11 |
| 7 | Portal | objectid | `invdata` type 20 |
| 8 | Spell / skill | name (and SN) | `slist` |
| 9 | Quest target | mob name | S&D target list |
| 10 | Channel | channel name | `comm.channel` |
| 11 | Vitals | — (observe only) | `char.vitals` |
| 12 | Combat event | — (observe only) | S0a |

**Handles are mostly free.** `invdata`/`eqdata` hand back a stable `objectid` for
every item — no guessing, no keyword heuristics. Only two entities need
derivation: occupants (solved — `ConsiderKeyword`) and floor items (open, §6).

### 4a. `invdata` is already parsed — but only half of it

`InventorySerials.swift` parses `invdata` (and `keyring data` / `vault data`)
today, for the Inventory Serials display feature. It reads **the first four
fields only** — `id, flags, name, level` — and explicitly discards the remaining
four, with the comment *"then 4 more fields we ignore"*.

One of those discarded fields is **`type`** — the field that identifies
**Portal (20)** and **Container (11)**. So the portal-list and bag-contents
journeys are not blocked on writing a parser; they are blocked on an existing
parser keeping four more columns. `eqdata` (worn equipment) shares the row format
but is not parsed at all.

This is the same pattern as everywhere else in this document: the feed is
understood, the parse exists, and it is scoped to one private consumer.
Widening `InventorySerials` into a shared item model is materially less work
than the "available, unused" framing would suggest — and materially different
work from writing one.

## 5. Readiness

Ranked by *(journey value) ÷ (work to first usable surface)*.

**Tier 1 — promotion only.** The feed is parsed and proven; it needs lifting out
of a private consumer.

1. **Occupants / mob targeting** — `{roomchars}` + `ConsiderKeyword`, both inside
   `ConsiderFeature`. Feeds the combat *and* navigation *and* quest journeys.
   Must exclude `(P)` entries (never offer to attack a player) — which also side-
   steps the pretitle name hazard entirely.
2. **Vitals / combat state** — `char.vitals` + `char.status`, already parsed.
   Immune to every display setting.

**Tier 2 — parse a documented structured feed.** No heuristics, no guessing.

3. **Items: worn, carried, bags, portals** — four journeys at once, with
   objectids as handles. Cheaper than it looks: `InventorySerials` already parses
   the row format and needs four more fields kept (§4a); `eqdata` reuses the same
   row shape.
4. **Spells / skills** — one `slist` parse yields the cast surface, including
   attack-vs-spellup and practiced %. `{sfail}` then explains failures.
5. **Floor items** — `{roomobjs}` is prose; needs a keyword derivation (§6).

**Tier 3 — needs a bridge out of Lua or new handling.**

6. **Quest targets** — S&D's list is reachable only from Lua today.
7. **Adjacent rooms** — `{scan}` parse; cheap, but its journey value depends on
   whether scouting is a lens anyone wants.
8. **`room.wrongdir`** — trivial, currently dropped on the floor.

**Tier 4 — S0a territory.** Combat flow as a graphical surface: the only
genuinely event-shaped item, and the one most exposed to `damage 0–6`. Use the
52-entry verb ladder's **ordinal position** as the magnitude proxy rather than
parsing damage numbers.

## 6. Open items

1. **Floor-item handles.** `{roomobjs}` gives prose (`A nondescript key lies here
   on the ground.`) with no objectid. `get key` works by keyword, so a derivation
   like `ConsiderKeyword`'s is the likely answer — but whether the mob heuristic
   transfers to objects is **unverified**. Do not assume it; check against
   recordings before designing.
2. **Which lenses ship.** Explicitly the user's call, and deliberately deferred
   until real play informs it — plan v0.1's instinct, reasserted by D-120.
3. **Player-authored lenses.** Out of scope. Unproven that players want to author
   on a phone.

## 7. What this tells S0a and S0b

**S0b (#84) — actionable state.** Twelve entities, mostly *promotion* of feeds
that already exist. The two genuinely new parsers are `invdata`/`eqdata` and
`slist`, both of which are documented CSV and each of which unlocks several
journeys at once. No line-pattern parsing is required for any Tier 1–3 entity.

**S0a (#82) — events.** The decomposition puts far less in S0a than the original
plan implied. Of twelve entities, exactly **one** is event-shaped (combat flow).
Everything else is state. The taxonomy should therefore be sized to: combat
events, plus what the existing soundpack vocabulary already fires, plus the
*transitions* that update entities (`{affon}`/`{affoff}`, `{invmon}`,
`comm.repop`, `comm.quest`). That is a much smaller and more defensible surface
than "classify the stream", and it is exactly the guard D-120 asked for.
