# Miniwindow demo plugins

Four self-contained MUSHclient plugins that exercise the **miniwindow spike**
(generic `Window*` support — see `docs/plans/MINIWINDOW_FEASIBILITY.md`). They
run through the generic `mush.lua` shim like any third-party plugin; none require
the Aardwolf shared libraries, so they load standalone.

| Plugin | Demonstrates |
|---|---|
| `mw_hello.xml` | Phase 1 — `WindowCreate` / `WindowRectOp` (fill + frame) / `WindowFont` / `WindowText` / `WindowLine`. A static panel, top-left. |
| `mw_gauge.xml` | Phase 1 + the **redraw-on-event** model — an `AddTimer` redraws a proportional bar each second, with text centred via `WindowTextWidth`. Top-centre. |
| `mw_buttons.xml` | Phase 2 — **hotspots**: three buttons with mouse-over highlight (`on_enter`/`on_leave`) and a mouse-up action (`on_click` → `Send`/`Note`). Centre-left. |
| `mw_shapes.xml` | Phase 4 — `WindowGradient`, `WindowCircleOp` (ellipse / round-rect), `WindowPolygon`, `WindowArc`, dashed/dotted `WindowLine`. Centre. |

## Loading them

In Proteles: **Plugins ▸ Plugin Library ▸ add a plugin from your Mac**, pick a
`.xml` file here (each is independent — load one or all four). They draw
immediately on install; `mw_gauge` animates once per second; click `mw_buttons`'
buttons to fire their callbacks.

## What to look for

- The windows float over the MUD output, positioned by each plugin's MUSHclient
  position constant (top-left, top-centre, centre-left, centre).
- Text is crisp at Retina scale (CoreText), shapes are antialiased, and each
  window has a subtle rounded clip + drop shadow — "nicer than MUSHclient" while
  keeping the plugin's own pixel geometry 1:1.
- Clicking a button in `mw_buttons` routes the gesture back into the plugin's Lua
  callback (UI → session → named function), which sends `look`/`score` or echoes
  a line.

## Not yet supported (Phase 5 — deferred by design)

Blend modes, image filters, `create_underneath` (draw *behind* the text),
pixel-exact font metrics, and `WindowMenu` popups. Plugins that call those
functions still load (the calls are benign no-ops/approximations); they just
don't render the exotic effect.
