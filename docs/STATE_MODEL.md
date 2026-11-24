# The actionable-state model

What exists **now** in the game, and the handle each thing is acted on by
(S0b, #84; D-121, D-129). The code is `Sources/MudCore/Semantic/State/`;
the State inspector (Settings ▸ Development) shows it live. This document
grows with each S0b item.

Two rules hold for every entity:

- **Feed absent is not empty.** An entity whose feed hasn't arrived this
  connection is *unknown* (`nil`), never an empty list. S0b switches no
  feed on (D-123).
- **Reference, don't copy.** The Mapper, `GMCPState`, `ChatStore` and S&D
  keep owning their data (D-129).

Consumers hear about changes through `NativePlugin.onStateChange(_:changed:)`,
which names the entities that changed. A feed-status change alone (a feed
first seen, a count) reaches only the UI.

## Feeds

| Feed | Kind | Read by |
|---|---|---|
| `{roomchars}`, `{roomobjs}`, `{invdata}`, `{eqdata}`, `{spellheaders}`, `{scan}` | tag block | `TagBlockCollector` |
| `{exits}`, `{invmon}` | tag line | `FeedMarker` |
| `room.info`, `char.vitals`, `char.status` | GMCP | the engine's GMCP seam |
| `consider` | command output (no tags) | `ConsiderWindow`, opened by the session's `sendLine` |

Design and measurements: `docs/plans/S0B_ITEM1_PROPOSAL.md` (the frame),
`docs/plans/S0B_ITEM2_PROPOSAL.md` (occupants).

## Occupants (item 2)

`ActionableState.occupants`. Entity: `.occupants`.

| | |
|---|---|
| **Presence** | `{roomchars}`: one line per occupant, with aura flags (`help auras`). It's the room's `look` text, so a mob appears as its *description*, not its name. |
| **Names** | Any whole-room `consider` (whoever sent it: the player, the Consider feature, S&D's smartscan fallback), or the `Right here you see:` section of `{scan}`. Bound to the `room.info` room they were taken in, and dropped on leaving it. A scan never replaces this room's consider list: consider sees noscan mobs. |
| **Handle** | The targeting keyword of each *named* mob, from `MobKeywordBook`: the player's override, then S&D's `mob_keyword_exceptions`, then the `gmkw` guess. Each keyword carries its source (`player`, `snd`, `guess`). Presence lines have no handle: only 44% of considered names appear in their room descriptions. |
| **Completeness** | Names are complete when they number as many mobs as `{roomchars}` shows. Pairing is by count, never by position. |
| **Players** | `(P)` or `(Player)`. Counted, never named, never a target. Names aren't parseable under pretitles anyway (`docs/AARDWOLF_DATA_FEEDS.md` §4). |
| **Unattackable** | Consider's lines for a mob that can't be attacked (divine protection, shopkeeper, a god's disapproval or smiting, already challenged): named, flagged, never targeted. |
| **Verified by** | Unit tests over recording fixtures (`OccupantsTests`, `OccupantsEngineTests`), and the corpus replay. The replay checks, with recognisers written separately: every `{roomchars}` block's non-player count equals the model's mobs, and every name list belongs to the room `room.info` last named. Considers are opened at the `.log`'s `SEND` times. |
| **Consumer** | `ConsiderFeature`: it adopts consider lists anyone sends, re-keys on keyword changes, clears on a room known to have no mobs, and sets overrides (`conw kw <n> [keyword]`). |

### Keywords (item 2, Q4)

`ActionableState.keywords`. Entity: `.keywords`.

| Layer | Source | Notes |
|---|---|---|
| Player | `~/Documents/Proteles/Databases/MobKeywords.db` (`MobKeywordOverrideStore`) | Proteles-owned; set with `conw kw` or the `.setMobKeyword` effect. |
| S&D | `SnDdb.db` `mob_keyword_exceptions`, read-only, on connect | S&D's seeded list plus the player's `xset kw`. |
| Guess | `ConsiderKeyword.heuristic` (S&D's `gmkw`) | First and last word, 5-letter prefixes, per-area fix-ups. |

Names match **ignoring case**: `consider` capitalises every name ("Best run
away from A deputy while you can!") while S&D stores names as written.
