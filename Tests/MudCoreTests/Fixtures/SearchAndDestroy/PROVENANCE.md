# Vendored Search-and-Destroy assets

Source: https://github.com/AardCrowley/Search-and-Destroy (submodule
`search-and-destroy/`, beta branch) by Crowley, plus helper libs from
`aardwolfclientpackage` (Fiendish). Vendored verbatim for the native Proteles
S&D plugin (logic reused unchanged; the MUSHclient miniwindow UI is replaced
by a native SwiftUI panel).

- `core.lua`            — the plugin's `<script>` CDATA, extracted verbatim
                          (UTF-8) from `Search_and_Destroy.xml`.
- `Search_and_Destroy.xml` — the full plugin, normalised to UTF-8; kept as the
                          source for the automation (trigger/alias/timer)
                          definitions. **Synced to the `proteles-snd-1.2` release**
                          (the version the in-app installer fetches via
                          `releases/latest`), so the parse/host tests validate the
                          shipped corpus (94 triggers, 100 aliases, 7 timers).
- `areaReferences.lua`, `sqlSetup.lua`, `tablesSetup.lua` — S&D's data modules.
- `constants.lua`       — S&D's `<include>`d constants.
- `wait.lua`            — coroutine async helper S&D `require`s.

## Proteles edits (plumbing, not logic)

`core.lua` is otherwise verbatim. The one intentional edit is a small
`[Proteles bridge]` block at the top of `xg_draw_window`: it publishes the
current model as JSON (`proteles.publish`) for the native SwiftUI panel and
`return`s, skipping the MUSHclient `Window*` drawing (which the native panel
replaces). It lives inside `core.lua` because it must read S&D's display
*locals* (`main_target_list`, `current_activity`, `quest_target`, `gqid_*`, …).
Search/campaign/gquest logic is untouched.

The bridge publishes `version`, `activity`, `player_on_cp`/`player_on_gq`,
`target_count`, `targets`, plus (added in `proteles-snd-1.3`) the open `quest`
(from `quest_target`: status/mob/area/area_name/room/killed), `can_request_quest`
(`quest_target.qstat == "0"`), and `gq_id` (`gqid_joined`, while on a GQ).

LICENSING: upstream S&D ships no explicit licence; redistribution terms are a
deferred decision (tracked with the GPLv3/starter-DB question). Vendored here
for development only.
