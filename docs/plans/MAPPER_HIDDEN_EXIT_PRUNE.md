# Proposal: stop pruning hidden cardinal exits on room revisit

**Status:** proposal — not implemented. Awaiting approval (mapper changes follow the
"propose first" workflow convention).
**Area:** MudCore / Mapper (`room.info` ingest + exit persistence).
**Severity:** correctness — silently severs map connectivity for areas reached
through hidden exits. Symptom is `mapper goto` → "No route found" to whole areas.

---

## 1. Symptom (how it surfaced)

Live play: every campaign target in the **Castle of Zangar** area (rooms
6175–6210 — Mineral Labyrinth, Ravine of Skulls, Amethyst Sea, Throne of Zangar)
returned `No route found` from `mapper goto`, even though the rooms exist in the
map and the player had been there before. Recording:
`session-20260620-161039.log` → `No route found to 6179` (×3), issued from zone
`wooble`.

Reachability analysis over the merged graph (shared `Aardwolf.db` +
`<char>/Aardwolf-personal.db`): the 30-room inner area is a directed **island** —
31,945 rooms reachable *from* 6179, but **zero walkable edges *into* it**. Aylor
recall reaches 31,915 rooms, not 6179.

The single entrance was `6174 (Red Lava) --d--> 6175 (The Fork)`. It is present
in the pre-migration backup and in the live MUSHclient map, but **absent from the
current Proteles map**. With that one cardinal exit gone, the whole area has no
inbound edge.

## 2. Root cause (proven from code, not inferred)

`6174 d→6175` is a **hidden exit**: Aardwolf's GMCP `room.info` for 6174 does not
advertise `d`. Proteles rebuilds a room's exit set from GMCP on every visit and
**deletes cardinal exits GMCP didn't report**:

- `Mapper.mergedExits` ([Sources/MudCore/Mapper/Mapper.swift:350](../../Sources/MudCore/Mapper/Mapper.swift))
  rebuilds the set as *(GMCP cardinals) ∪ (carried-forward exits)* — but the
  carry-forward loop only keeps **non-cardinal** exits:

  ```swift
  for (dir, exit) in existing?.exits ?? [:] {
      guard !RichExits.isCardinalDirection(dir), exits[dir] == nil else { continue }
      exits[dir] = exit
  }
  ```

  A previously-known **cardinal** exit whose dir is missing from this visit's GMCP
  payload is *not* carried forward.

- `MapperStore.saveExits` ([Sources/MudCore/Mapper/MapperStore.swift:162](../../Sources/MudCore/Mapper/MapperStore.swift))
  then delete-then-inserts the cardinal side:

  ```sql
  DELETE FROM exits WHERE fromuid = ? AND dir IN ('n','s','e','w','u','d','ne','nw','se','sw')
  -- re-insert only the cardinals in the merged set (i.e. only the GMCP-advertised ones)
  ```

So on the next visit to a hidden-exit room, GMCP omits the hidden direction and
Proteles drops it. This is the **only** code path that deletes a cardinal exit on
a normal visit (the D-111 split deletes only non-cardinals + the `*`/`**`
pseudo-rooms; everything else is explicit `mapper delete`/`purge`).

### Reference behaviour (the spec we should match)

The Aardwolf package mapper **never prunes** exits on a room update. Its
`save_room_exits`
([submodules/aardwolfclientpackage/MUSHclient/worlds/plugins/aard_GMCP_mapper.xml:4128](../../submodules/aardwolfclientpackage/MUSHclient/worlds/plugins/aard_GMCP_mapper.xml))
only upserts the GMCP-reported directions:

```lua
for dir,touid in pairs(gmcpdata.exits) do
   INSERT OR REPLACE INTO exits (dir, fromuid, touid) VALUES (dir, uid, touid)
   rooms[uid].exits[dir] = touid
end
-- no DELETE: a known exit GMCP didn't mention is left untouched
```

Every `DELETE FROM exits` / `exits[...] = nil` in the reference is inside an
explicit user command — `map_cexits_delete`, `map_exit_delete_to/from`,
`map_cexits_purge`, `map_portal_edit/purge/recall`, `purgezone`,
`map_purgeroom`, `room_delete_exit`, `room_change_cexit_command`. None runs on a
normal `room.info`. So once MUSHclient learns a hidden exit it keeps it forever
unless the player explicitly deletes it.

Proteles' own comment at `mergedExits` already cites this — *"the reference's
`save_room_exits` likewise only upserts GMCP dirs and never deletes custom
exits"* — but it stops at *custom*. The reference never deletes **cardinal**
exits either; that's the gap the carry-forward restriction misses.

### Empirical confirmation (your data)

| Source | `6174 d→6175` | Notes |
|---|---|---|
| `Aardwolf-premigration-backup.db` (Proteles) | present | learned, pre-split |
| current `Aardwolf.db` (Proteles) | **gone** | pruned on a revisit |
| `<char>/Aardwolf-personal.db` | — | not relocated; deleted, not moved |
| live MUSHclient `Aardwolf.db` | present | reference never pruned |

Scope across the whole map — cardinal exits present in the Proteles pre-migration
backup but missing from the current Proteles map: **61**. Of those, **35 are
retained byte-identically in the live MUSHclient DB** (same from/dir/dest), **0**
differ in destination, and 26 are absent from MUSHclient only because they were
first explored in Proteles after the May-17 MUSHclient snapshot. The 35 retained
are textbook hidden exits — *A Hidden Passage*, *A hidden cave*, *Deep Crypt*,
*Above an Open Grave*, *Tunnel!*, *Beneath the Glass Pillar*, the 4-way
`1098 Pulsing Purple Ichor` hub, `6187 d→6188`, and `6174 d↔6175`.

This is the decisive corroboration: MUSHclient ran the reference for years and
kept these exits; Proteles dropped them. Your MUSHclient DB is unaffected
precisely because the reference never prunes.

## 3. Proposed fix

Make Proteles match the reference: **never drop a known exit just because this
visit's GMCP payload omitted it.** GMCP still *wins* for any direction it does
report (add new, replace changed destination); it just no longer *removes*.

One-line change in `mergedExits` — drop the cardinal restriction so the
carry-forward keeps any known direction GMCP didn't mention:

```swift
// before
for (dir, exit) in existing?.exits ?? [:] {
    guard !RichExits.isCardinalDirection(dir), exits[dir] == nil else { continue }
    exits[dir] = exit
}

// after — carry forward ANY known exit GMCP didn't report this visit
// (cardinal or custom), matching the reference's never-prune semantics.
for (dir, exit) in existing?.exits ?? [:] where exits[dir] == nil {
    exits[dir] = exit
}
```

Why this is sufficient and self-contained:

- The first loop still applies every GMCP direction, preserving per-exit
  metadata (level/weight/door) when the destination is unchanged and replacing it
  when GMCP reports a new destination. **GMCP always wins for dirs it reports.**
- The merged set now includes carried-forward hidden cardinals, so
  `saveExits`'s existing delete-then-insert re-inserts them — they persist in the
  shared DB. **`saveExits` needs no change** (its delete-then-insert becomes
  equivalent to an upsert once the set is complete).
- In-memory `graph` and the DB stay consistent (both keep the exit), so there's
  no memory/DB divergence until reload.

### Why this is safe

- **No spurious mismatch warnings.** Proteles has no automatic exits-mismatch
  detection in the ingest path; `ignoreExitsMismatch` is a stored, reference-import
  flag and is not consulted to gate updates. Carrying extra exits forward changes
  nothing there.
- **Less write churn.** `sameRoom` ([Mapper.swift:463](../../Sources/MudCore/Mapper/Mapper.swift))
  currently treats a hidden-exit revisit as *changed* (one fewer exit) and
  re-persists the prune every time; after the fix, revisits to unchanged rooms are
  no-ops.
- **Faithful to the reference's accepted trade-off.** A cardinal exit that is
  *genuinely* removed in-game will now linger until the player runs
  `mapper delete exits …` — exactly how MUSHclient behaves. Hidden exits don't
  change, so this is the right default.

## 4. Test plan (must fail before the change)

Add to `Tests/MudCoreTests/Mapper/MapperRoomInfoTests.swift`:

1. **Hidden cardinal survives a revisit.** Ingest `room.info` for room A with
   exits `{n:B, d:C}`. Re-ingest A with GMCP exits `{n:B}` only (hidden `d`
   omitted). Assert A still has `d→C` in both `graph` and the persisted `exits`
   table. (Fails today — `d→C` is pruned.)
2. **GMCP still wins on a changed destination.** A has `n→B`; re-ingest with
   `n→X`; assert `n→X` (replace, not duplicate).
3. **Custom exits keep working** (regression guard for the existing behaviour):
   an `open down;down→C` survives a revisit that omits it.
4. **Pathfinder reachability.** Build A↔…↔hidden-entrance, prune-then-route, and
   assert a route exists after a revisit (integration-level guard mirroring the
   Zangar case).

All four mapper gates (`swift build`, `swift test --parallel`,
`swiftformat --lint .`, `swiftlint --strict`) must stay green.

## 5. Optional follow-up: one-time backfill of already-lost exits

The code fix prevents *future* loss but does not restore the ~35+ exits already
dropped. Those rooms will **not** re-map naturally — they're hidden, so GMCP never
re-adds them; they stay lost until each is manually re-walked/cexited (as 6174 was).

A one-time repair could re-insert cardinal exits that are present in
`Aardwolf-premigration-backup.db` but missing from the current shared map (the
backup is the same map's own history; safest source). Staleness risk is low
because the affected exits are overwhelmingly secret/hidden passages that don't
change, but the candidate list should be **reviewed before applying** (a handful
could be rooms that legitimately changed). I can generate the full candidate list
(from-room, dir, dest, both room names) for sign-off, and gate the apply behind a
`mapper` maintenance command or a guarded migration.

This is secondary to the code fix and can ship separately.

## 6. Scope / risk

- One-line behavioural change in `mergedExits`; no schema change; `saveExits`
  untouched.
- Risk surface: rooms whose exits legitimately disappear now linger — matches the
  reference and is correctable via `mapper delete`. No connectivity is lost.
- Backfill (if done) is reviewable and reversible (re-inserts only; a stale row is
  removable via `mapper delete`).
