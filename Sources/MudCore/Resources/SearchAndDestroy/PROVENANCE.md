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
                          definitions.
- `areaReferences.lua`, `sqlSetup.lua`, `tablesSetup.lua` — S&D's data modules.
- `constants.lua`       — S&D's `<include>`d constants.
- `wait.lua`            — coroutine async helper S&D `require`s.

LICENSING: upstream S&D ships no explicit licence; redistribution terms are a
deferred decision (tracked with the GPLv3/starter-DB question). Vendored here
for development only.
