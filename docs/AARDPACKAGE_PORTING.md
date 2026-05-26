# aardwolfclientpackage — native porting tracker

Living status of the deliberate effort to bring the Aardwolf MUSHclient
package's 43 plugins to Proteles. Source XMLs (reference only):
`aardwolfclientpackage/MUSHclient/worlds/plugins/`.

## Strategy (decided; see PLAN.md §7/§11, D-23/D-28/D-33/D-34)

- **None of these run through the generic `mush.lua` shim.** Each is brought
  over as a **native app feature** or a pure-Swift **`NativePlugin`** — or, for
  large UI-heavy plugins, **vendored verbatim** on a dedicated curated-binding
  runtime (the S&D model). The shim stays only for arbitrary 3rd-party plugins.
- **Per-plugin verdict first:** `drop` / `native feature` / `native plugin` /
  `vendor-verbatim` / `reimplement-differently`. Then PROPOSE a deep-dive plan
  and wait for approval before coding. **Not all plugins are relevant**, and
  some are good ideas best done the native way.
- **No guessing:** research the reference XML + `mushclient/` + `mudlet/` and
  use live transcripts/DBs.

### Key dependency finding

The two most-depended-on plugins — `aard_repaint_buffer` (15 callers) and
`aard_miniwindow_z_order_monitor` (10 callers) — plus `mw_theme_base`,
`movewindow`, `themed_miniwindows`, `gauge`, `scrollbar`, `text_rect` are **all
MUSHclient miniwindow-rendering infrastructure**. Native SwiftUI panels replace
the lot, so they're dropped and the dependency graph collapses. After that, the
only real cross-plugin deps are the GMCP handler, the mapper, chat echo, and
text substitution — **all already native** — so remaining work has **no hard
ordering**; sequence by value.

## Status table (43)

Legend: ✅ done · 🔨 build (Phase A/B) · 🎨 reimplement-differently (native) ·
🕓 defer to UI revamp · 🗑️ drop · ❓ verify

| Plugin | Verdict | Notes |
|---|---|---|
| aard_GMCP_handler | ✅ done | native `AardGMCPHandler` (D-33): `sendgmcp` + config synthesis |
| aard_GMCP_mapper | ✅ done | native graphical mapper (D-25/D-29) |
| aard_chat_echo | ✅ done | native `ChatEcho` |
| aard_text_substitution | ✅ done | native `TextSubstitution` |
| aard_note_mode | ✅ done | native `NoteMode` |
| aard_vital_shortcuts | ✅ done | native `VitalShortcuts` |
| aard_ASCII_map | ✅ done | native `AsciiMap` |
| aard_channels_fiendish | ❓ verify | likely covered by native Chat panel (#30/#31) + ChatEcho |
| aard_group_monitor_gmcp | ✅ done (core) | covered by the native Info-panel group section (#33): members + level + HP/MP/MV bars + here-indicator. Miniwindow replaced by the native panel. Display refinements deferred to the UI revamp (see below). |
| aard_prompt_fixer | ✅ done (native, ⏳ live) | **dropped the plugin**; replaced with the protocol-correct native fix (D-35): `LinePipeline` flushes the pending line on `IAC GA` so a prompt is always its own `Line` and anchored triggers fire — no server-side prompt rewrite. Live-verify GA presence + rendering (batch). |
| Aardwolf_Tick_Timer | 🔨 build | tick countdown from `comm.tick` GMCP — small HUD feature |
| aard_inventory_serials | 🔨 build | serial #s in inventory output — small line-rewrite plugin (pairs w/ dinv) |
| aard_soundpack | 🔨 build | comm/event sounds — native `AVAudioPlayer` |
| aard_health_bars_gmcp | 🔨 build | extend the native status HUD (#29) |
| aard_statmon_gmcp | 🔨 build | extend the native status HUD (#29) |
| Omit_Blank_Lines | 🔨 build | tiny native output option |
| SAPI + universal_text_to_speech | 🎨 reimplement | one native TTS feature on `AVSpeechSynthesizer` (TTS scope still to investigate) |
| Hyperlink_URL2 | 🎨 reimplement | native URL detection in the TextKit output view |
| aard_Copy_Colour_Codes | 🎨 reimplement | native "copy w/ @-codes / copy as HTML" (backlog #1/#2) |
| aard_Theme_Controller | 🕓 defer | native theming — UI revamp |
| aard_splitscreen_scrollback | 🕓 defer | native split-scroll in output view — UI revamp |
| aard_vi_review_buffers | 🕓 defer | categorized scrollback review — UI revamp |
| aard_VI_command_output | 🕓 defer | capture command output to a panel — UI revamp |
| aard_ingame_help_window | 🕓 defer | in-game help → native panel — UI revamp |
| Aardwolf_Bigmap_Graphical | 🕓 defer | server bigmap → fold into map panel — UI revamp |
| aard_repaint_buffer | 🗑️ drop | miniwindow repaint coalescing (15 callers) — native panels |
| aard_miniwindow_z_order_monitor | 🗑️ drop | miniwindow z-order (10 callers) — native panels |
| aard_layout | 🗑️ drop | arranges miniwindows on screen |
| aard_requirements | 🗑️ drop | package requirement/version manager |
| aard_package_update_checker | 🗑️ drop | online package update check (Sparkle handles updates) |
| MUSHclient_Help | 🗑️ drop | opens the MUSHclient help file |
| aard_help | 🗑️ drop | help for package plugin commands (ours have native help) |
| plugin_list | 🗑️ drop | lists installed plugins (Plugins window) |
| plugin_summary | 🗑️ drop | plugin summary (Plugins window) |
| Config_Option_Changer | 🗑️ drop | edits MUSHclient world-file options (app settings, not game) |
| aard_new_connection | 🗑️ drop | package onboarding UI (Connection Manager) |
| aard_new_connection_no_UI | 🗑️ drop | auto-connect (autologin) |
| Time | 🗑️ drop | clock miniwindow |
| Automatic_Backup | 🗑️ drop | copies the MUSHclient world file (different persistence model) |
| aard_keyboard_lockout | 🗑️ drop | `aard input lock/unlock` — niche |
| aard_translate_foreign_friends | 🗑️ drop | ftalk → online translation API (external service) |
| aard_Command_Tag_Handler | 🗑️ drop | hides `{Command:…}` tags — moot unless we enable the command-tag stream |

Counts: 7 done · 8 build · 4 reimplement · 6 defer · 17 drop · 3 verify (= 45
rows because TTS = 2 plugins → 1 feature, so 43 plugins).

## Work order

**Phase A — quick, high-value native, no new UI subsystems:**
`Aardwolf_Tick_Timer`, `aard_inventory_serials`, `Omit_Blank_Lines`; and the
verify-then-likely-resolve trio (`aard_prompt_fixer`,
`aard_group_monitor_gmcp`, `aard_channels_fiendish`).

**Phase B — native features with new subsystems:**
TTS (investigate first), `aard_soundpack`, copy-@-codes/HTML + hyperlinks,
HUD extensions (`aard_health_bars_gmcp`, `aard_statmon_gmcp`).

**Phase C — deferred to the UI revamp:** theming, splitscreen scrollback,
review buffers, command-output capture, in-game help window, bigmap.

### Group-monitor display refinements (deferred to the UI revamp)

The native group section (`InfoPanel.swift`) covers the essentials; the
`aard_group_monitor_gmcp` extras are panel UX/polish to fold in when the panel
system is reworked:
- Leader indicator (model already has `group.leader`).
- Align bar + align-coloured names; quest-timer (`qt`) column — needs extending
  `GroupInfo.Member.Info` (no `qt`/`qtstring` field yet).
- Sorting (by HP %/total damage, by quest timers).
- HP numbers overlaid on the bars.
- Display preferences: on/off, room-only filter (`grouproom`), compact mode,
  per-player show/hide (`showp`/`hidep`).

## Pending live verification (batched)

Per the user's decision, live/interactive MUD verification is **batched** rather
than per-plugin. Each item below passed unit tests + the four gates; confirm
behaviour against the live MUD (and a session transcript) in one pass:

- **`aard_prompt_fixer` → GA prompt boundary (D-35):** confirm Aardwolf sends
  `IAC GA` after prompts (recordings are MCCP2-compressed, so not greppable
  offline); confirm prompts render as their own lines, anchored triggers fire,
  and autologin still matches the name/password prompts.

**Finale — dinv** (vendored inventory manager): resumed only **after all
aardwolfclientpackage plugins are done**. Blocker #1 (`sendgmcp`) is cleared by
D-33; remaining: add `SetEchoInput` + `DoAfterSpecial`, verify the `config`
reply live. Strip the temporary `[dinv-DBG]` instrumentation when it resumes.
