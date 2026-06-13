# Inventory serials — native implementation plan

> **Status: shipped (feature-complete for 1.0). Historical design doc — kept for the rationale and trade-offs.** Implemented as the `InventorySerials` NativePlugin (`Sources/MudCore/Scripting/NativePlugins/InventorySerialsPlugin.swift`) over the pure `InventorySerialsParser` (`Sources/MudCore/LineModel/InventorySerials.swift`).
>
> Native port of Fiendish's `aard_inventory_serials`
> (id `0cbb10309587f0ee15ba78ce`): adds item **serial numbers** + flag colours +
> grouped counts to `inventory` / `keyring list` / `vault list` output. You
> greenlit implementing it; this was the concrete build plan. Reference:
> `submodules/aardwolfclientpackage/.../aard_inventory_serials.xml`.

## How the reference works
Intercepts the `inventory` (+ `keyring list`, `vault list`) aliases. Instead of
the plain command it sends the **data** form (`invdata` / `keyring data` /
`vault data`), which Aardwolf returns as a CSV block wrapped in
`{invdata}…{/invdata}` (etc.) tags. It parses each row
(`id,flags,name,level,…` via `^(\d+),(\w*),(.+),(\d+),(\d+),([01]),(-?\d+),(-?\d+)`),
**groups identical items** (same flags+name+level), and re-renders the list with
counts, flag colours (`(B)`lue aura, `(K)`ept, `(M)`agic, …), the serial id(s)
(or "many" if >3), and the level. `invdata` is a plain command — **no telnet
tag option needed** (unlike Help/exits), which makes this simpler than Help.

## This is a Help-sized capture/parse/re-render — but self-contained

Good fit for a **`InventorySerials` NativePlugin** (toggleable, "plus setting"),
not a controller flag — because it's a discrete command interception, not a
global display mode. Reuses the tag-block capture pattern I built for Help.

### Pieces
- **MudCore `InventorySerialsParser` (pure, unit-tested)** — the CSV row regex →
  `[InvItem { id, flags, name, level }]`, grouping identical items, and
  rendering the styled output lines (counts + flag colours + serials + level).
  Cross-check the CSV shape against **dinv's `dinv_items.lua`** (dinv parses the
  same `invdata` stream — authoritative for the format, avoids guessing).
- **`InventorySerials` NativePlugin**:
  - `handleCommand("inventory"/"i"/"inv"/…, "keyring list", "vault list")` →
    when serials are on (or a one-shot `… serials`): echo the typed command,
    emit `.sendNoEcho("invdata")` (etc.), set an internal `capturing` state.
    When off: return `nil` (command passes through unchanged).
  - `onLine` (the capture state machine, like Help's): on `{invdata}` open →
    buffer + gag; buffer rows (gag); on `{/invdata}` → parse + group + emit the
    re-rendered styled lines (echo effects), clear state. Same for keyring/vault
    (and the keyring "be awake" note the reference handles).
  - Commands: `inventory serials on/off` (always-show mode, persisted),
    `inventory serials color <@code>`, `inventory serials help`, plus the
    one-shot `inventory serials` / `keyring list serials` / `vault list serials`.
  - Persisted per world via `NativePluginStore` (the "setting"); toggle in the
    Plugins window.

### Reuse from already-shipped work
- The **tag-block capture** approach is exactly Help's `captureHelpLine`
  pattern (buffer between open/close tags, gag, emit on close) — but lives in
  the plugin's own state (self-contained), since it's command-scoped.
- Styled re-render = build `Line`s with `@`-coloured runs (we have
  `AardwolfColor.styledLine`) and emit as echo effects (like the mapper's notes).
- Flag-colour map is small + static (from the reference's `color_lookup`).

## Why it was held back overnight (historical)
It needed **live `invdata`-format verification** (the exact CSV columns + the
keyring/vault variants + the "asleep" edge case): better to confirm the format
against dinv's parser + one live capture than ship untested re-rendering. That
verification was done and the plan below was executed.

## Phases
1. `InventorySerialsParser` (pure + tests against sample `invdata` rows from the
   reference/dinv) — no live dependency, fully testable.
2. The `InventorySerials` NativePlugin: command interception + capture + re-render
   for **inventory** first; toggle + persistence + Plugins-window entry.
3. keyring + vault variants; `serials on/off/color/help` commands; the keyring
   "be awake" note.
4. Live-verify the format + rendering (your side); adjust if columns differ.

## Decisions (resolved)
1. **Default**: off, one-shot via `inventory serials`, with `serials on` for
   always — matching the reference. *(Adopted.)*
2. Bundled like the native ports, default-off. *(Adopted — it's a clean native
   plugin, toggleable in the Plugins window.)*
3. Interaction with **dinv**: both consume `invdata` but run independently (dinv
   on its own command), so no conflict; both are available. *(Confirmed.)*

## Effort
Medium (Help-sized): a pure parser + a stateful NativePlugin + live format
verification. Lower risk than Help (no telnet-option negotiation).
