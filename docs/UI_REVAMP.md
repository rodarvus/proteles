# Proteles UI revamp — layout system (proposal + design)

Status: **in progress** (first implementation landing alongside this doc).
Author: this session (2026-05-27). Decisions confirmed with the user up front
(see "Confirmed decisions").

## Problem

Today the main window is a left **output column** (MUD text + command input +
text status bar) and a **single right dock** that shows exactly **one** panel at
a time, chosen by a segmented picker (Info / Map / Chat / S&D). You cannot see
the map *and* chat *and* S&D simultaneously — the opposite of what a MUD power
user needs. The status bar duplicates as text what the gauges already show. The
input field loses focus when you select text in the output.

Goal: **show all enabled/active panels at once**, densely and elegantly, with
show/hide, drag-resize, and rearrange — on a normal laptop screen — while
keeping the command input always ready to type.

## Confirmed decisions (from the user)

1. **Resizable tiled dock** — panels live in resizable split regions you can
   rearrange and collapse; several can stack as tabs in one slot. **No
   overlapping free-floating windows** (rejected: the MUSHclient/Mudlet model is
   messy, overlaps, and fights focus).
2. **Single window now, architected to detach later** — everything lives in one
   window (fits a laptop, no "lost behind the game window" problem); the model
   is built so tearing a panel into its own macOS window is a clean future add.
3. **Curated default + easy show/hide** — ship a sensible default arrangement;
   overflow panels are a click/keystroke away or tab-grouped. (Not: cram every
   panel tiny.)
4. **Layout structure first** — this pass is the layout system + arrangement +
   full-width gauges + always-focused input. Keep current colors/typography;
   theming is a later, separate pass.

## How the references do it (research)

- **MUSHclient** (the user's 49" Aardwolf setup): a big main text window with
  ~10 **miniwindows** tiled/floated around it (group, channels, graphical map,
  stats, text map, S&D, rich-exits, NPC-scan, help) plus a bottom row of
  HP/MP/MV/enemy gauges. Miniwindows are absolutely-positioned, z-ordered,
  drawn by plugins via a low-level canvas API, with clickable hotspots. It works
  because the screen is enormous. The model is a 20-year-old Windows canvas API;
  we deliberately don't copy it — but the *information set* (the ten panels +
  gauges) is the target feature parity.
- **Mudlet / Geyser** (cross-platform Lua): a **box-layout tree**. `Container`s
  hold child windows with constraint specs (`"50%"`, `"300px"`, `"-20px"` =
  offset-from-edge). `HBox`/`VBox` auto-organize children along an axis with
  proportional or pixel sizes and re-flow on resize. `AdjustableContainer` adds
  runtime drag/resize with save/restore. Primitives: `MiniConsole`, `Label`,
  `Gauge`, `Mapper`. **This is the useful idea**: nestable H/V boxes with
  fractional sizing == a layout tree. Our design is the native-SwiftUI
  equivalent, but expressed as a value-typed, persistable, testable tree.
- **macOS-native primitives / inspiration**: `NSSplitView` (native resizable
  panes with divider autosave), Xcode's areas (navigator / editor / inspector /
  debug rails), the SwiftUI `.inspector` modifier, Stage Manager's tidy tiling,
  and tabbed terminals (iTerm2 split panes). The throughline: **structured,
  non-overlapping, resizable regions** beat free-floating windows for density
  and learnability.

## Architecture

### Layout data model — `MudCore` (pure, Codable, unit-tested)

The layout is a value tree, decoupled from SwiftUI so it can be unit-tested and
persisted per world:

```
PanelKind          // enum: which panel (output, map, textMap, channels, hunt, info, group, …)
PanelLayout        // indirect enum: the tree
  .leaf(PanelKind)
  .tabs(panels: [PanelKind], selection: Int)      // tab-grouped panels in one slot
  .split(axis, items: [PanelLayout.Item])         // resizable region
PanelLayout.Item { fraction: Double; node: PanelLayout }
LayoutAxis         // .horizontal | .vertical
```

Pure operations (all tested): `panels` (set present), `contains`, `removing`,
`showing(_:in:)`, `resized(path:divider:delta:)`, `normalized` (fractions sum to
1, degenerate splits/tabs collapse), Codable round-trip, and named **presets**.

Why a tree (vs. fixed rails): a tree is the minimal structure that expresses
*any* tiling — rails, mosaics, nested groups — so it's future-proof for detach,
new panels, and user presets without rework. It mirrors Geyser's H/V box nesting
exactly, but typed.

### Rendering — `MudUI` (recursive, declarative)

`PanelLayoutView` walks the tree:
- `.split` → an H/V stack sized from each item's `fraction` (via `GeometryReader`),
  with a thin **draggable divider** between items that writes the new fractions
  back to the model (clamped to a min size). This is the "drag to resize" + the
  Geyser `AdjustableContainer` behavior, done natively.
- `.tabs` → a compact tab strip + the selected panel (the density trick: stack
  S&D / Text Map / Help in one slot).
- `.leaf` → the panel's content, supplied by the app via a
  `panelContent(PanelKind) -> some View` closure so the layout engine stays
  decoupled from session/model wiring.

The **main output** is itself a `PanelKind` (`.output`) — so it resizes/arranges
like any panel. Its leaf renders the MUD text **plus the full-width graphical
gauges** (HP/MP/MV/enemy) beneath it (the "stat bars span the main window"
requirement) — no duplicated text.

Show/hide is a **Panels menu** (View menu + a toolbar control): each `PanelKind`
is a checkbox; toggling inserts/removes it from the tree. Closing a panel's
chrome ✕ removes it; a panel picker re-adds it.

### Always-focused command input

The command `NSTextField` is the window's default first responder. The output
`NSTextView` stays mouse-selectable but **forwards keyDown** to the command
field (and refocuses it) so typing a command always lands in the input even
right after you select/copy from the scrollback. (Implemented in
`MudOutputView_macOS`.)

### Persistence & presets

The chosen `PanelLayout` is Codable and persisted **per world** (alongside the
profile), so different characters can keep different arrangements. Built-in
presets ship as starting points; "Reset layout" restores the default.

## Default preset (laptop-friendly)

```
┌───────────────────────────────┬───────────────┐
│                               │     Map       │   right rail (≈38%)
│        MUD output             ├───────────────┤
│        (largest)              │ S&D │ TextMap │   (tab group)
│                               ├───────────────┤
│                               │   Channels    │
├───────────────────────────────┤               │
│ HP ▓▓▓  MP ▓▓  MV ▓▓  Enemy ▓ │               │   full-width gauges
└───────────────────────────────┴───────────────┘
```

Tree: `split(.horizontal, [ {0.62, leaf(output)},
{0.38, split(.vertical, [ {0.45, leaf(map)}, {0.30, tabs([hunt, textMap])},
{0.25, leaf(channels)} ])} ])`. Info/Group/Help are off by default, one toggle
away. All four user-required panels (graphical map, text map, S&D, channels) are
visible at once.

## Roadmap

- **This pass (v1):** the model + tests, recursive renderer with drag-resize +
  tab groups, the default preset, full-width gauges, always-focused input,
  Panels show/hide, per-world persistence. Replaces the single-panel dock.
- **Next:** drag-and-drop to *re-dock* a panel between regions (v1 uses the
  Panels menu + tab grouping); user-savable named presets; the remaining panels
  (Text Map content, Help, NPC-scan, Rich-exits); detach-to-window; theming.
