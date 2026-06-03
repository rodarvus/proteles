# Command-button bar (#15) — design + status

A configurable quick-command button bar: clickable buttons that fire a command
(or a script), grouped into pages, in a dockable/floating panel. **Shipped
v1–v3 (D-97).**

## Reference (Mudlet)

Mudlet models buttons as a tree of `TAction` (bar → groups → buttons), authored
in the Trigger Editor's "Buttons" tree. A bar has a *location* (top/left/right/
floating) + *orientation* + *column count*; buttons are momentary, two-state
("push-down" toggle, up/down commands), or script buttons; folders become
drop-down menus. **Lua can only control existing buttons** (`getButtonState`/
`setButtonState`/`setButtonStyleSheet`) — it can't create them.

## Proteles design

- **Model (MudCore, per-world):** `ButtonBar { groups: [ButtonGroup] }`,
  `ButtonGroup { name, buttons }`, `CommandButton { label, action: MacroAction,
  kind: .momentary | .toggle(off:), tint?, icon?, hotkeyEcho? }`. Persisted in
  `ScriptDocument` (tolerant decode) like triggers/aliases/timers/macros. Reuses
  `MacroAction` (`.command`/`.script`) + `session.fire` so buttons run through
  the normal pipeline (aliases/mapper/S&D intercept).
- **Panel (`PanelKind.commandBar`):** rides the existing tile dock — dock it
  top/bottom for a **horizontal bar**, left/right for a **column/grid**, or
  detach to a **floating window**. An adaptive `LazyVGrid` flows buttons to fill,
  so *orientation follows placement* (no manual columns). Group tabs (segmented
  control) page between groups. Toggle buttons fill solid when on; per-button
  tint + SF Symbol icon + an optional hotkey-echo badge.
- **Editor:** a dedicated **Scripts ▸ Buttons** tab (group list with inline
  rename + add/delete; a `CommandButtonEditor` for label/action/toggle/tint/icon/
  hotkey).
- **Scripting API (the Mudlet-beating bit):** `Button.add(group,label,command)`,
  `Button.toggle(group,label,on,off)`, `Button.state(label,on)`,
  `Button.remove(label)` → `proteles.button(...)` → a `.button` `ScriptEffect`
  the session streams to the app, which applies it to the live bar + persists.
  So a plugin/trigger can **create + update + toggle** buttons (e.g. a combat
  plugin lights a "Wimpy ON" toggle; S&D adds a "Next target" button). Buttons
  are addressed by label.

## Deferred / iterate
- Toggle state is transient (not persisted) — persist per-world if wanted.
- GMCP-driven toggle visuals (a toggle reflecting live state) — natural follow-up
  via `Button.state` from a GMCP trigger.
- Reordering groups/buttons by drag in the editor (model methods exist:
  `moveButtonGroups`/`moveButtons`); the editor currently adds/deletes.
