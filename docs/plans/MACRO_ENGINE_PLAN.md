# MacroEngine — design + the one-key/keypad problem on macOS

> **Status: shipped (feature-complete for 1.0; D-50, v0.3.0). Historical design
> doc — kept for the rationale and trade-offs.** `MacroEngine`, the `NSEvent`
> monitor, numpad/chord/function-key tiers, the Navigation-mode toggle, defaults,
> and the Macros editor all landed. The paired command-button bar also shipped
> (GitHub #15). See `../DECISIONS.md` (D-50).

> Plan deliverable (no code). A **macro** = a key (or key chord) bound to a
> command or script. The hard part on macOS is **one-key (keypad-style)
> navigation** — sending a movement on a *bare* keypress while a text input has
> focus. This doc proposes the model and how to make one-key feasible.

## The model (mirrors the trigger/alias/timer engines)

- **MudCore `MacroEngine` (pure, value-type, unit-tested)** — holds a set of
  `Macro { chord: KeyChord, action: MacroAction }`, persisted per world (like
  `ScriptStore`). `match(_ chord:, context:) -> Macro?` is a pure lookup.
- **`KeyChord`** — `keyCode: UInt16` + `modifiers` (⌘/⌥/⌃/⇧) + `isKeypad: Bool`.
  Identity is platform-neutral (raw keycodes), so the engine is testable
  without AppKit.
- **`MacroAction`** — `.command(String)` (sent like typed input, through the
  pipeline so `;`-stacking + aliases work) or `.script(String)` (run in the
  user script env). Reuses the existing send/script effect paths.
- **App `MacroMonitor` (macOS)** — an `NSEvent.addLocalMonitorForEvents(matching:
  .keyDown)` that, on each keyDown, builds a `KeyChord`, asks the engine for a
  match given the current **context**, fires the action + **swallows the event**
  (returns nil) on a hit, else returns the event unchanged (normal typing).

## The one-key conflict (and the resolution)

The command input is an `NSTextField` with focus, so a bare keypress normally
goes into the text. Three tiers of binding, by conflict risk:

1. **Modifier chords (⌘/⌥/⌃ + key) and function keys (F1–F12)** — never
   conflict with typing. *Always fire.* The safe default surface.
2. **Numeric keypad keys** — macOS reports `NSEvent.modifierFlags.numericPad`
   + distinct keycodes for the numpad, so they're distinguishable from the main
   row. *Fire whenever bound*, even with the input focused. This is the classic
   MUD numpad-navigation surface (KP-8 = north, KP-2 = south, …).
   - **Caveat:** Mac laptops + Magic Keyboard have **no numpad**. So numpad
     macros require an external keyboard. We can't assume one.
3. **Bare main-keyboard keys** (e.g. `n`/`s`/arrows with no modifier) — these
   *do* conflict with typing. Resolution: fire a bare-key macro **only when the
   command input is empty** AND an opt-in **"Navigation mode"** is on. The
   moment you type anything, bare keys go to text; clear the line and they
   navigate again. A visible indicator shows when navigation mode is active.

So **one-key navigation is feasible** via: numpad (external keyboards) +
modifier/function chords (always) + an opt-in empty-input "Navigation mode" for
laptop users who want bare-key movement. We ship sensible defaults (numpad →
directions; arrow keys → directions in navigation mode) the user can edit.

### Arrow keys + a "Navigation mode" toggle
Bind a toggle (e.g. ⌥⌘N or a button) that flips Navigation mode. While on,
arrow keys / hjkl / numpad send movement even with focus; a status chip shows
"NAV". This gives laptop users the keypad experience without a keypad.

## Persistence + editing
- Macros persist per world alongside triggers/aliases (extend `ScriptStore` or
  a sibling `MacroStore`).
- A **Macros tab** in the Scripts editor (see SCRIPTS_EDITOR_REWORK_PLAN.md):
  a list + a "Record a key" capture field (press the key → it fills the chord),
  an action field (command or script), and tier indication (warns if a bare key
  will only fire in Navigation mode).

## Defaults to ship
- Numpad: 8=n 2=s 4=w 6=e 7=nw 9=ne 1=sw 3=se; KP-plus/minus or 5 = up/down;
  KP-0 = look; KP-`.` = recall. (Matches the long-standing MUD numpad layout.)
- These are *editable defaults*, created on first run, not hardcoded.

## Pairing opportunity (from the Mudlet gap analysis) — shipped
A **command-button bar** (Mudlet's TAction) is the natural sibling: the same
`MacroAction` model, surfaced as clickable on-screen buttons for users who
prefer the mouse. `MacroAction` was designed to serve both from day one, and the
button bar shipped as the fast follow (GitHub #15; see
`COMMAND_BUTTON_BAR.md`).

## Decisions for the user (resolved as shipped)
1. **Scope of v1**: chords + function keys + numpad + the Navigation-mode
   empty-input path — all of it, or start with chords/numpad only? → shipped the
   full surface.
2. **Navigation mode**: opt-in toggle (recommended) vs always-on empty-input
   bare-key firing (riskier — surprises while typing)? → opt-in toggle.
3. **Button bar**: design `MacroAction` to support it now (cheap) even if the UI
   comes later? → yes; the UI shipped (GitHub #15).
4. Default numpad layout — confirm the mapping above matches your muscle memory.
   → shipped as editable defaults.

## Effort (as built)
Medium, as estimated. The engine + persistence + editor was comparable to a
trigger editor. The `NSEvent` monitor was small but needed careful focus/
empty-input/keypad logic and live testing across keyboard types (laptop vs
external numpad).
