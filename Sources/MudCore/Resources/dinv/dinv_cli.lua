----------------------------------------------------------------------------------------------------
-- Command-Line Interface Parser
--
-- The CLI interface consists of components that each have a base parsing function, a function to
-- display the component's usage, and a function to display examples using the component.
--
-- The components are:
--   Inventory table access: build, refresh, search
--   Item management:        get, put, store, keyword, organize
--   Equipment sets:         set, snapshot, priority
--   Equipment analysis:     analyze, usage, compare, covet
--   Advanced options:       backup, notify, forget, ignore, reset, cache, tags
--   Using equipment:        portal, consume, pass
--   About the plugin:       version, help
--
-- Functions
--   inv.cli.fullUsage()
--
--   inv.cli.build.fn(name, line, wildcards)
--   inv.cli.build.usage()
--   inv.cli.build.examples()
--   inv.cli.refresh.fn(name, line, wildcards)
--   inv.cli.refresh.usage()
--   inv.cli.refresh.examples()
--   inv.cli.search.fn(name, line, wildcards)
--   inv.cli.search.usage()
--   inv.cli.search.examples()
--
--   inv.cli.get.fn(name, line, wildcards)
--   inv.cli.get.usage()
--   inv.cli.get.examples()
--   inv.cli.put.fn(name, line, wildcards)
--   inv.cli.put.usage()
--   inv.cli.put.examples()
--   inv.cli.store.fn(name, line, wildcards)
--   inv.cli.store.usage()
--   inv.cli.store.examples()
--   inv.cli.keyword.fn(name, line, wildcards)
--   inv.cli.keyword.usage()
--   inv.cli.keyword.examples()
--
--   inv.cli.set.fn(name, line, wildcards)
--   inv.cli.set.usage()
--   inv.cli.set.examples()
--   inv.cli.weapon.fn(name, line, wildcards)
--   inv.cli.weapon.usage()
--   inv.cli.weapon.examples()
--   inv.cli.priority.fn(name, line, wildcards)
--   inv.cli.priority.fn2(name, line, wildcards)
--   inv.cli.priority.usage()
--   inv.cli.priority.examples()
--   inv.cli.snapshot.fn(name, line, wildcards)
--   inv.cli.snapshot.usage()
--   inv.cli.snapshot.examples()
--
--   inv.cli.analyze.fn(name, line, wildcards)
--   inv.cli.analyze.fn2(name, line, wildcards)
--   inv.cli.analyze.usage()
--   inv.cli.analyze.examples()
--   inv.cli.usage.fn(name, line, wildcards)
--   inv.cli.usage.usage()
--   inv.cli.usage.examples()
--   inv.cli.unused.fn(name, line, wildcards)
--   inv.cli.unused.usage()
--   inv.cli.unused.examples()
--   inv.cli.compare.fn(name, line, wildcards)
--   inv.cli.compare.usage()
--   inv.cli.compare.examples()
--   inv.cli.covet.fn(name, line, wildcards)
--   inv.cli.covet.usage()
--   inv.cli.covet.examples()
--
--   inv.cli.notify.fn(name, line, wildcards)
--   inv.cli.notify.usage()
--   inv.cli.notify.examples()
--   inv.cli.forget.fn(name, line, wildcards)
--   inv.cli.forget.usage()
--   inv.cli.forget.examples()
--   inv.cli.ignore.fn(name, line, wildcards)
--   inv.cli.ignore.usage()
--   inv.cli.ignore.examples()
--   inv.cli.reset.fn(name, line, wildcards)
--   inv.cli.reset.usage()
--   inv.cli.reset.examples()
--   inv.cli.backup.fn(name, line, wildcards)
--   inv.cli.backup.usage()
--   inv.cli.backup.examples()
--   inv.cli.cache.fn(name, line, wildcards)
--   inv.cli.cache.usage()
--   inv.cli.cache.examples()
--   inv.cli.tags.fn(name, line, wildcards)
--   inv.cli.tags.usage()
--   inv.cli.tags.examples()
--
--   inv.cli.portal.fn(name, line, wildcards)
--   inv.cli.portal.usage()
--   inv.cli.portal.examples()
--   inv.cli.consume.fn(name, line, wildcards)
--   inv.cli.consume.usage()
--   inv.cli.consume.examples()
--
--   inv.cli.organize.fn1(name, line, wildcards)
--   inv.cli.organize.fn2(name, line, wildcards)
--   inv.cli.organize.fn3(name, line, wildcards)
--   inv.cli.organize.usage()
--   inv.cli.organize.examples()
--
--   inv.cli.migrate.fn(name, line, wildcards)
--   inv.cli.migrate.usage()
--   inv.cli.migrate.examples()
--
--   inv.cli.version.fn(name, line, wildcards)
--   inv.cli.version.usage()
--   inv.cli.version.examples()
--   inv.cli.reload.fn(name, line, wildcards)
--   inv.cli.reload.usage()
--   inv.cli.reload.examples()
--   inv.cli.help.fn(name, line, wildcards)
--   inv.cli.help.usage()
--   inv.cli.help.examples()
--
----------------------------------------------------------------------------------------------------

inv.cli = {}

function inv.cli.fullUsage()
  dbot.print("@C" .. pluginNameCmd .. " usage:@W Command @GRequired @YOptional@w")

  dbot.print("\n@C  Inventory table access@w")
  inv.cli.build.usage()
  inv.cli.refresh.usage()
  inv.cli.search.usage()

  dbot.print("\n@C  Item management@w")
  inv.cli.get.usage()
  inv.cli.put.usage()
  inv.cli.store.usage()
  inv.cli.keyword.usage()
  inv.cli.organize.usage()

  dbot.print("\n@C  Equipment sets@w")
  inv.cli.set.usage()
  inv.cli.weapon.usage()
  inv.cli.snapshot.usage()
  inv.cli.priority.usage()

  dbot.print("\n@C  Equipment analysis@w")
  inv.cli.analyze.usage()
  inv.cli.usage.usage()
  inv.cli.unused.usage()
  inv.cli.compare.usage()
  inv.cli.covet.usage()

  dbot.print("\n@C  Advanced options@w")
  inv.cli.backup.usage()
  inv.cli.forget.usage()
  inv.cli.ignore.usage()
  inv.cli.migrate.usage()
  inv.cli.notify.usage()
  inv.cli.regen.usage()
  inv.cli.report.usage()
  inv.cli.reset.usage()
  inv.cli.cache.usage()
  inv.cli.tags.usage()
  inv.cli.reload.usage()

  dbot.print("\n@C  Using equipment items@W")
  inv.cli.consume.usage()
  inv.cli.portal.usage()
  inv.cli.pass.usage()

  dbot.print("\n@C  Plugin info@w")
  inv.cli.version.usage()
  inv.cli.help.usage()

end -- inv.cli.fullUsage


-- Returns nil if ready, or a DRL_RET_* failure code the caller should
-- propagate (typically via inv.tags.stop for tracked commands).
function inv.cli.requireReadyStateFor(noun)
  if (not inv.init.initializedActive) then
    dbot.info("Skipping " .. noun .. " request: plugin is not yet initialized (are you AFK or sleeping?)")
    return DRL_RET_UNINITIALIZED
  elseif dbot.gmcp.statePreventsActions() then
    dbot.info("Skipping " .. noun .. " request: character's state does not allow actions")
    return DRL_RET_NOT_ACTIVE
  end -- if
end -- inv.cli.requireReadyStateFor


-- Like requireReadyStateFor, but rejects the combat state too.
function inv.cli.requireActiveStateFor(noun)
  if (not inv.init.initializedActive) then
    dbot.info("Skipping " .. noun .. " request: plugin is not yet initialized (are you AFK or sleeping?)")
    return DRL_RET_UNINITIALIZED
  elseif (not dbot.gmcp.stateIsActive()) then
    dbot.info("Skipping " .. noun .. " request: character is not in the active state")
    return DRL_RET_NOT_ACTIVE
  end -- if
end -- inv.cli.requireActiveStateFor


inv.cli.build = {}
function inv.cli.build.fn(name, line, wildcards)
  local confirmation = Trim(wildcards[1] or "")
  local endTag = inv.tags.new(line, "Build completed", nil, inv.tags.cleanup.timed)

  dbot.debug("inv.cli.build.fn: confirmation = \"" .. confirmation .. "\"")

  if (confirmation == "") then
    dbot.print(
[[

  Building your inventory table can take several minutes and may disturb
  other players as you shuffle items through your inventory.

  If you truly want to build your inventory table:
    1) Go to a room where you won't disturb other people]])
   dbot.print("    2) Enter \"" .. pluginNameCmd .. " build confirm\"")
   dbot.print("    3) Wait for the build to complete or enter \"" .. pluginNameCmd ..
              " refresh off\" to halt early\n")
    inv.tags.stop(invTagsBuild, endTag, DRL_RET_UNINITIALIZED)

  elseif (confirmation == "confirm") then
    dbot.backup.preBuild()
    dbot.info("Build confirmed: Prompts will be disabled until the build completes")
    dbot.info("Commencing inventory build...")
    inv.items.build(endTag)
  else
    inv.cli.build.usage()
    inv.tags.stop(invTagsBuild, endTag, DRL_RET_INVALID_PARAM)
  end -- if
end -- inv.cli.build.fn


function inv.cli.build.usage()
  dbot.print("@W    " .. pluginNameCmd .. " build confirm@w")
end -- inv.cli.build.usage


function inv.cli.build.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.build.usage()

  dbot.print(
[[@W
The heart of this plugin is an inventory table that tracks information about
all of your items.  Before you can use that table, you must first build it.
This is a relatively long process and can take several minutes to complete.
A build requires a fair amount of communication with the mud and latency to
the mud will have a significant impact on the speed of the build.

As an example, my primary character currently is holding 548 items and took
just under 5 minutes to build an inventory table from scratch when I used
my normal internet connection with a ~40 ms latency to the mud.  I also used
a VPN to access the mud from various points around the world and found that
a connection with a ~130 ms latency completed the same build in 8 minutes and
a ~440 ms latency connection (thank you New Zealand!) took 18 minutes to
complete a full build.  Fortunately, building your inventory table should be
a one-time operation and subsequent changes to your table will be quick and
easy.

Building your inventory table requires the plugin to run the "identify"
operation on all of your items.  If an item is in a container, it will first
take the item out of the container before identifying it and putting it back.
Similarly, if you are wearing an item, the plugin will first remove the item,
identify it, and then re-wear it at its original location.  All of this will
be transparent to you.  However, anyone in the same room as you will see lots
of activity as the plugin shuffles items around.  As a result, please be kind
to those around you and find an out-of-the-way room for the build operation.
Don't do this at recall! :)

If you do not have the identify wish, it may be beneficial for you to do
your build at Hester's room (from recall: runto ident).  When you identify
something in Hester's room, you pay a small fee in gold, but you see a full
identification including fields you normally wouldn't (e.g., weapon damtype).

While the build executes, you are free to do your normal mudding activities.
However, the build will halt if you sleep, go AFK, enter combat, or do
something that puts you at a paging prompt so it's probably easiest if you
sit back and just let the plugin do its thing :)

If you need to stop the build for some reason, simply go to sleep or go AFK.
Either of those modes will halt the build.  You can pick up where a partial
build stopped by running "@Gdinv refresh@W".

If you interrupted a build by going to sleep or going AFK, the build will
automatically continue at the next refresh attempt (see "@Gdinv help refresh@W"
for more details.)  You can disable automatic refreshes with the command
"@Gdinv refresh off@W" and you can re-enable them with "@Gdinv refresh on@W".
A new installation starts with automatic refreshes disabled by default.

Once you have a completed inventory table available, you probably want to make
a manual backup in case something goes wrong in the future.  You can restore
from the backup and avoid the long build process again.  If anything in your
inventory has changed since the backup, your next refresh will simply update
it to what you currently have.  To make a manual backup named
"@Gmy_first_awesome_backup@W" type "@Gdinv backup create my_first_awesome_backup@W".
See "@Gdinv help backup@W" for more details about creating, viewing, and restoring
backups.
]])

end -- inv.cli.build.examples


inv.cli.refresh = {}
function inv.cli.refresh.fn(name, line, wildcards)
  local command       = wildcards[1] or ""
  local refreshPeriod = tonumber(wildcards[2] or "") or inv.items.timer.refreshMin
  local refreshLoc
  local retval
  local endTag

  dbot.debug("inv.cli.refresh.fn: command=\"" .. command .. "\", period=\"" .. refreshPeriod .. "\"")

  if (command == "all") then
    refreshLoc = invItemsRefreshLocAll
    endTag = inv.tags.new(line, "Inventory refresh full scan done", nil, inv.tags.cleanup.timed)
  else
    refreshLoc = invItemsRefreshLocDirty
    endTag = inv.tags.new(line, "Inventory refresh done")
  end -- if

  if (command == "off") then
    retval = inv.items.refreshOff()
    dbot.info("Automatic inventory refresh is disabled: run \"@G" .. pluginNameCmd ..
              " refresh on@W\" to re-enable it")
    inv.tags.stop(invTagsRefresh, endTag, retval)

  elseif (command == "on") then
    retval = inv.items.refreshOn(refreshPeriod, 0)
    dbot.info("Inventory refresh is enabled")
    inv.tags.stop(invTagsRefresh, endTag, retval)

  elseif (command == "eager") then
    retval = inv.items.refreshOn(refreshPeriod, inv.items.timer.refreshEagerSec or 0)
    dbot.info("Inventory refresh is enabled and uses eager refreshes after acquiring items")
    inv.tags.stop(invTagsRefresh, endTag, retval)

  elseif (command == "") or (command == "all") then
    if (inv.state == invStatePaused) then
      inv.state = invStateIdle
    end -- if

    if (command == "") then
      dbot.info("Inventory refresh scan: start basic refresh")
    else
      dbot.info("Inventory refresh scan: start full refresh")
    end -- if

    local retval = inv.items.refresh(0, refreshLoc, endTag, nil)
    if (retval == DRL_RET_HALTED) then
      dbot.note("Run \"" .. pluginNameCmd .. " refresh on\" to re-enable automatic inventory refreshes")
    end -- if

  else
    inv.cli.refresh.usage()
    inv.tags.stop(invTagsRefresh, endTag, DRL_RET_INVALID_PARAM)
  end -- if

end -- inv.cli.refresh.fn


function inv.cli.refresh.usage()
  dbot.print("@W    " .. pluginNameCmd .. " refresh @Y[on | off | eager | all] <minutes>@w")
end -- inv.cli.refresh.usage


function inv.cli.refresh.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.refresh.usage()

  dbot.print(
[[@W
If you add a new item to your inventory or remove an item from your inventory, your inventory
table must be informed about the change.  A refresh operation is the means through which the
plugin updates your inventory table.  When the plugin detects changes to your inventory it will
check if automated refreshes are enabled and, if so, schedule an automated "refresh" to identify
anything that has changed.

A refresh operation may require the plugin to get an item from a container or remove a worn item
in order to identify the item.  If the plugin moves (or removes) the item, it will automatically
put the item back when the identification completes.  The plugin suppresses mud output related
to this moving and identification so it will appear to happen transparently from the user's
perspective.

There are two types of refreshes: manual and automatic.  A manual refresh simply performs a
refresh when the user requests one.  An automatic refresh occurs when a timer expires after a
specified period of time.  Automatic refreshes are disabled by default on a new installation.
If automatic refreshes are turned on ("@Gdinv refresh on <minutes>@W") then an automatic refresh
runs every N minutes since the previous automatic refresh (if N is not supplied, it will default
to 5 minutes.)  If nothing has changed since the last refresh, the refresh simply returns.

If you really *really* like your inventory to always be up-to-date, you should use the "eager"
refresh mode ("@Gdinv refresh eager <minutes>@W").  This is identical to the "refresh on" mode
described above but it will also schedule a refresh to run 5 seconds after an item is added to
your inventory.

The plugin will skip a refresh or halt it early if you go to sleep, go AFK, enter combat, or hit
a paging prompt.  In this case, any changes that were missed will be picked up the next time a
refresh is in progress.

You may also execute a refresh that performs a full scan of all worn items, items in your main
inventory, and items in containers.  Your first refresh after starting up will be a full scan to
ensure that everything is in the expected place.  Otherwise, your inventory table could become
out of sync if you logged in with another client and moved items around.  The full scan guarantees
that the plugin knows where everything is.

Examples:
  1) Perform a manual refresh
     "@Gdinv refresh@W"
  2) Disable automatic refreshes
     "@Gdinv refresh off@W"
  3) Enable automatic refreshes with the default period (5 minutes since the last refresh)
     "@Gdinv refresh on@W"
  4) Enable automatic refreshes with a 10-minute delay between refreshes
     "@Gdinv refresh on 10@W"
  5) Enable automatic refreshes with a 7-minute delay between refreshes and an "eager" refresh
     a few seconds after a new item is added to your inventory
     "@Gdinv refresh eager 7@W"
  6) Perform a manual full refresh scan
     "@Gdinv refresh all@W"
]])
end -- inv.cli.refresh.examples


inv.cli.search = {}
function inv.cli.search.fn(name, line, wildcards)
  local verbosity = wildcards[1] or ""
  local query = wildcards[2] or ""
  local endTag = inv.tags.new(line)

  -- Use the "basic" display mode for searches by default
  if (verbosity == "") then
    verbosity = "basic"
  end -- if

  dbot.debug("verbosity=\"" .. verbosity .. "\", query=\"" .. query .. "\"")

  local retval = inv.items.display(query, verbosity, endTag)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.cli.search.fn: Failed to display search query: " .. dbot.retval.getString(retval))
  end -- if

end -- inv.cli.search.fn


function inv.cli.search.usage()
  dbot.print("@W    " .. pluginNameCmd .. " search @Y[objid | full] @G<query>@w")
end -- inv.cli.search.usage


function inv.cli.search.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.search.usage()
  dbot.print(
[[@W
An inventory table isn't much help if you can't access it!  That's where search queries come
into play.  A query specifies characteristics about inventory items and returns matches for
all items that match the query.  Queries are used in many of the dinv plugin's modes.  For
example, the "@Cget@W", "@Cput@W", "@Cstore@W", "@Ckeyword@W", "@Corganize@W", and "@Cusage@W" options all take query
arguments and then get, put, store, etc. whatever items match the query.  See the helpfile at
"@Gdinv help query@W" for more details and examples.

A query consists of one or more sets of key-value pairs where the key can be any key listed
when you identify/lore an item.  For example, a query could be "@Gtype container keyword box@W"
if you wanted to find everything with a type value of "container" that has a keyword "box".

Queries also support three prefixes that can be prepended onto a normal key: "@Cmin@W", "@Cmax@W",
and "@C~@W" (where "@C~@W" means "not").  To find weapons with a minimum level of 100 that do not have
a vorpal special, you could use this query: "@Gtype weapon minlevel 100 ~specials vorpal@W".

You can also "OR" multiple query clauses together into a larger query using the "@C||@W" operator.
If you want move all of your potions and pills into a container named "2.bag" you could do that
with this command: "@Gdinv put 2.bag type potion || type pill@W".

Most queries are in the form "someKey someValue" but there are a few one-word queries that make
life a bit simpler.  If a query is the string "all" it will match everything in your inventory --
including everything you are wearing, everything you are holding in your main inventory, and
everything in your containers.  If you use the "worn" query, it will only match items that are
currently equipped.  If you use an empty query (i.e., the query is "") then it will match
everything in your inventory that is not currently equipped.

Search queries support both absolute and relative names and locations.  If you want to specify
all weapons that have "axe" in their name, use "@Gtype weapon name axe@W".  If you want to
specifically target the third axe in your main inventory, use "@Gtype weapon rname 3.axe@W"
(or you could just get by with "@Grname 3.axe@W" and skip the "@Gtype weapon@W" clause.)  The use
of the key "rname" instead of "name" means that the search is relative to your main inventory
and you can use the format [number].[name] to target a specific item.  Similarly, you can use
"@Grlocation 3.bag@W" to target every item contained by the third bag in your main inventory
(i.e., the third bag is their relative location.)

There are a few "one-off" query modes for convenience.  It is so common to search for just a
name that the default is to assume you are searching within an item's name if no other data
is supplied.  In other words, "@Gdinv search sunstone@W" will find any item with "sunstone" in
its name.  Also, 'keyword', 'key' and 'kw' are accepted aliases for 'keywords', 'loc' is an
alias for 'location' and 'rloc' is an alias for 'rlocation'.  Yeah, I'm lazy sometimes...

Performing a search will display relevant information about the items whose characteristics match
the query.  There are three modes of searches: "@Cbasic@W", "@Cobjid@W", and "@Cfull@W".  A basic search displays
just basic information about the items -- surprise!  An objid search shows everything in the basic
search in addition to the item's unique ID.  A full search shows lots of info for each item and is
very verbose.

Examples:
  1) Show basic info for all weapons between the levels of 1 to 40
     "@Gdinv search type weapon minlevel 1 maxlevel 40@W"

@WLvl Name of Weapon           Type     Ave Wgt   HR   DR Dam Type Specials Int Wis Lck Str Dex Con
@W  8@w a @yFlame@rthrower@w           @Wexotic   @G  4@W   0 @G  10@W @G  18@W Fire     none     @G  2@W   0 @G  3@W   0   0   0
@W 11@w @YDagger of @RAardwolf@w       @Wdagger   @G 27@W @G  1@W @G   5@W @G   5@W Cold     sharp      0   0   0   0   0   0
@W 20@w @WS@we@Wa@wr@Wi@wn@Wg @wB@Wl@wa@Wz@we            @Wwhip     @G 30@W @G  3@W @G   2@W @G   2@W Fire     flaming  @G  1@W @G  4@W @G  7@W @G  1@W   0   0
@W 26@w @bM@Belpomene's @bB@Betrayal@w     @Wdagger   @G 36@W @G  1@W @G   2@W @G   2@W Pierce   sharp      0   0   0   0 @G  2@W   0
@W 40@w @YDagger of @RAardwolf@w       @Wdagger   @G100@W   0 @G  20@W @G  20@W Fire     sharp    @G  1@W   0   0   0   0   0
@W 40@w @YDagger of @RAardwolf@w       @Wdagger   @G100@W @G 10@W @G   5@W @G   5@W Mental   sharp      0   0   0   0   0   0
@W
  2) Show unique IDs and info for all level 91 ear and neck items
     "@Gdinv search objid wearable ear level 91 || wearable neck level 91@W"

@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W 91@w @c:@C:@W:@CSt@cerling @G(1851993170) @Wear         0 @G  12@W @G  4@W   0 @G  3@W   0   0   0 @G  9@W    0 @G  30@W @R -60
@W 91@w Kilhil's Ble @G(907478999) @Wear         0 @G  16@W @G  2@W @G  2@W @G  2@W   0 @G  6@W   0 @G  9@W    0    0    0
@W 91@w @y>@Y}@rPho@Ren@Yix's @G(1584559998) @Wneck     @G   2@W @G  14@W @G  1@W @G  4@W @G  1@W @G  2@W @G  1@W @G  2@W @G  9@W    0    0    0
@W 91@w @Dthe @YAmulet  @G(1235973081) @Wneck        0 @G  12@W   0   0 @G  3@W @G  4@W   0   0 @G  9@W    0    0    0
@W 91@w @Dthe @YCharm   @G(1745132926) @Wneck     @G   6@W @G   6@W @G  4@W   0 @G  2@W   0   0   0 @G  9@W    0    0    0
@W
  3) Show full info for anything with an anti-evil flag
     "@Gdinv search full flag anti-evil@W"

@WLvl Name of Weapon           Type     Ave Wgt   HR   DR Dam Type Specials Int Wis Lck Str Dex Con
@W 20@w @WS@we@Wa@wr@Wi@wn@Wg @wB@Wl  @G(1743467081) @Wwhip     @G 30@W @G  3@W @G   2@W @G   2@W Fire     flaming  @G  1@W @G  4@W @G  7@W @G  1@W   0   0
@w    colorName:"@WS@we@Wa@wr@Wi@wn@Wg @wB@Wl@wa@Wz@we" objectID:1743467081
@w    keywords:"searing blaze vengeance"
@w    flags:"unique, glow, hum, magic, anti-evil, held, resonated, illuminated, V3"
@w    score:309 worth:2690 material:steel foundAt:"Unknown"
@w    allphys:0 allmagic:0 slash:0 pierce:0 bash:0 acid:0 poison:0
@w    disease:0 cold:0 energy:0 holy:0 electric:0 negative:0 shadow:0
@w    air:0 earth:0 fire:0 water:0 light:0 mental:0 sonic:0 magic:0
@w    weight:3 ownedBy:""
@w    clan:"From Crusaders of the Nameless One" affectMods:""@w
@W
  4) Show info on any containers that are wearable on your back
     "@Gdinv search type container wearable back@W"

@WLvl Name of Container        Type       HR   DR Int Wis Lck Str Dex Con Wght  Cap Hold Hvy #In Wgt%
@W201@w @MP@mandora@w'@ms @R[@GBox@R]@w          @GContain @W @G  20@W @G  26@W @G  5@W   0 @G  3@W   0   0 @G  5@W @R   8@W @G1500@W @G  16@W @G 50@W @G 33@W @G  50
@W
  5) Show info on any portals leading to the Empire of Talsa
     "@Gdinv search type portal leadsTo talsa@W"

@WLvl Name of Portal           Type     Leads to            HR  DR Int Wis Lck Str Dex Con
@W 60@w @BIrresistible Calling@w     @Wportal   The Empire of Tals   0   0   0   0   0   0   0   0
@W100@w @REvil Intentions@w          @Wportal   The Empire of Tals   0   0   0   0   0   0   0   0
@W150@w @BCosmic Calling@w           @Wportal   The Empire of Tals   0   0   0   0   0   0   0   0@W

  6) Look at sorted lists of your poker cards and aardwords tiles
     "@Gdinv search key poker || key aardwords@W"

@WLvl Name of Trash            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W  1@w @Y|@C4@Y[@CFour of Air@Y]@C4@Y|@w        @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @Y|@y4@Y[@yFour of Earth@Y]@y4@Y|@w      @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @Y|@c4@Y[@cFour of Water@Y]@c4@Y|@w      @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @Y|@CA@Y[@CAce of Air@Y]@CA@Y|@w         @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @Y|@cA@Y[@cAce of Water@Y]@cA@Y|@w       @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @Y|@CD@Y[@CDemon of Air@Y]@CD@Y|@w       @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @Y|@cE@Y[@cElemental of Water@Y]@cE  @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @Y|@CM@Y[@CMephit of Air@Y]@CM@Y|@w      @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @Y|@cM@Y[@cMephit of Water@Y]@cM@Y|@w    @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@w
@WLvl Name of Treasure         Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W  1@w @RAardWords (TM)@Y - Double  @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @RAardWords (TM)@Y - Double  @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @RAardWords (TM)@Y - Triple  @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @RAardWords (TM)@Y - [B] - S @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @RAardWords (TM)@Y - [E] - S @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @RAardWords (TM)@Y - [H] - S @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @RAardWords (TM)@Y - [P] - S @Whold        0    0   0   0   0   0   0   0   0    0    0    0
@W  1@w @RAardWords (TM)@Y - [W] - S @Whold        0    0   0   0   0   0   0   0   0    0    0    0

  7) Find armor that is enchantable
     "@Gdinv search type armor flag invis || type armor ~flag hum || type armor ~flag glow@W"

  8) Display your items that are equipped
     "@Gdinv search worn@W"

  9) Display EVERYTHING (no I'm not pasting that output here!)
     "@Gdinv search all@W"

 10) Find owned wearables that are not part of any analyzed set for the @Cmage@W priority
     (i.e., gear that the @Gdinv analyze@W output for @Cmage@W never picks up).  Combines with
     other tags so you can scope the search; use the @C~@W prefix to invert the match.
     "@Gdinv search wearable head unused mage@W"
     "@Gdinv search type weapon ~unused mage@W"
     "@Gdinv put 2.bag unused all@W"

 11) Find all items in your main inventory (not worn, not in a container)
     "@Gdinv search loc inventory@W"
]])

end -- inv.cli.search.examples


-- This isn't a full CLI module, but the query example helpfile seemed to fit well here
inv.cli.query = {}
function inv.cli.query.examples()
dbot.print(
[[@W
Queries are based on key values found in an item's description when you identify
an item.  All fields are visible if you have the identify wish.  If you do not have
the identify wish, some fields may only be seen with an identify spell or with the
lore ability.

A query's format includes one or more key-value pairs.  Details on this can be
found at the helpfile displayed by the command "@Gdinv help search@W" but let's give a
few more examples here too.  You can never have too many examples :)

The plugin supports a few special queries that are not in the "someKey someValue"
format:
   @Call@W: Matches everything you have equipped or are carrying
  @Cworn@W: Matches all of your worn equipment
    @C""@W: The "empty query" matches everything in your inventory that is not equipped

Examples:

  1) Use a single key-value pair to find items that are level 42
     [key] [value]
     "@Gdinv search level 42@W"

  2) Use two key-value pairs to find items that match *both* pairs.  In this example
     we find all weapons with the "aardwolf" keyword (i.e., aard quest weapons).  By
     default, two key-value pairs next to each other require an item to match the
     first pair and the second pair.
     [key1] [value1] [key2] [value2]
     "@Gdinv search type weapon keyword aardwolf@W"

  3) Use the "@C||@W" operator (it means "or") with two key-value pairs to find items
     that match *either* pair.  To find all wearable finger or wrist items, use the
     query shown below.
     [key1] [value1] || [key2] [value2]
     "@Gdinv search wearable finger || wearable wrist@W"

  4) Use the "@Cmin@W" and "@Cmax@W" prefixes.  You can prepend "min" or "max" prefixes to
     any numeric key (e.g., level, weight, str, etc.) to indicate that you only want
     to match items up to a minimum or maximum value.  Let's find all wearable head
     items between levels 50 to 100.
     "min"[key 1] [value1] "max"[key2] [value 2]
     "@Gdinv search wearable head minlevel 50 maxlevel 100@W"

  5) Things get a little more complicated if we want to use both "and" and "or" clauses
     in the same query.  The "and" operation (putting two key-value pairs next to each
     other) has a higher precedence than "or", as represented by the "@C||@W" symbols.
     If we want to find weapons with the "mental" or "pierce" damage types that are at
     least level 100, we need to duplicate the "minlevel 100" key-value pair for both
     halves of the query.  We don't use parentheses to indicate precedence.  That would
     add more complexity than I'm comfortable with at this point...
     [key1] [value1] [key2] [value2] || [key3] [value3] [key2] [value2]
     "@Gdinv search damtype mental minlevel 100 || damtype pierce minlevel 100@W"

  6) Find all armor that has a weight of at least 10 and at most 20 that does not have
     an "anti-evil" flag.  The "@C~@W" symbol indicates "not" when it is used as a prefix
     for a key in a key-value pair.
     "@Gdinv search type armor minweight 10 maxweight 20 ~flag anti-evil@W"

  7) Find everything in the container with relative location name "2.bag"
     "@Gdinv search rloc 2.bag@W"

  8) Match everything you currently have equipped
     "@Gdinv search worn@W"

  9) Match everything in your inventory that is not equipped
     "@Gdinv search@W"

 10) Match everything you have equipped or are carrying
     "@Gdinv search all@W"

Queries support lots of keys that are found when you identify an item.  Here is the
list of currently supported keys:
]])

  local sortedStats = {}
  for key,statField in pairs(inv.stats) do
    table.insert(sortedStats, statField)
  end -- for

  table.sort(sortedStats, function (entry1, entry2) return entry1.name < entry2.name end)

  for _, statField in ipairs(sortedStats) do
    dbot.print(string.format("@C%15s@W: %s", statField.name, statField.desc))
  end -- for

end -- inv.cli.query.examples


inv.cli.get = {}
function inv.cli.get.fn(name, line, wildcards)
  local query = wildcards[1] or ""
  local endTag = inv.tags.new(line)

  dbot.debug("CLI: " .. pluginNameCmd .. " get \"" .. query .. "\"")

  local guardFail = inv.cli.requireReadyStateFor("get")
  if guardFail then return inv.tags.stop(invTagsGet, endTag, guardFail) end

  inv.items.get(query, endTag)
end -- inv.cli.get.fn


function inv.cli.get.usage()
  dbot.print("@W    " .. pluginNameCmd .. " get @G<query>@w")
end -- inv.cli.get.usage


function inv.cli.get.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.get.usage()

  dbot.print(
[[@W
The "get" option works in a similar manner to the normal mud "get" command.  It moves
something (or somethings) into your main inventory.  The main difference is that you don't
need to specify from where you are getting the item(s).  An item may be worn or in a
container or on your keyring and it will still move automagically into your main inventory.

A "get" request takes a query argument as a parameter.  See "@Gdinv help search@W" for more
details on how queries work and to see several examples of queries.

You may mark containers as "ignored" to prevent dinv from accessing items in those containers.
See the "@Gdinv help ignore@W" helpfile for instructions and examples.

Examples:
  1) Move all level 42 items into your main inventory
     "@Gdinv get level 42@W"

  2) Move all weapons with a fire damage type into your main inventory
     "@Gdinv get damtype fire@W"

  3) Get all potions or pills that are in a container at relative location 4.bag
     "@Gdinv get rloc 4.bag type potion || rloc 4.bag type pill@W"

  4) Get anything with a key type or a flag indicating it's a key
     "@Gdinv get type key || flags iskey@W"

  5) Get everything with a custom keyword named "borrowedFromBob" (see "@Gdinv help keyword@W"
     for details on how to add custom keywords to items)
     "@Gdinv get key borrowedFromBob@W"

  6) Get anything that is worn on a finger at level 131
     "@Gdinv get wearable finger level 131"
]])

end -- inv.cli.get.examples


inv.cli.put = {}
function inv.cli.put.fn(name, line, wildcards)
  local container = wildcards[1] or ""
  local query = wildcards[2] or ""
  local endTag = inv.tags.new(line)

  dbot.debug("CLI: " .. pluginNameCmd .. " put \"" .. container .. "\", \"" .. query .. "\"")

  local guardFail = inv.cli.requireReadyStateFor("put")
  if guardFail then return inv.tags.stop(invTagsPut, endTag, guardFail) end

  inv.items.put(container, query, endTag)
end -- inv.cli.put.fn


function inv.cli.put.usage()
  dbot.print("@W    " .. pluginNameCmd .. " put @G<container relative name> <query>@w")
end -- inv.cli.put.usage


function inv.cli.put.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.put.usage()

  dbot.print(
[[@W
The "put" option works in a similar manner to the normal mud "put" command.  It moves
something (or somethings) from your main inventory into a container at a relative location.
The main difference is that you don't need to specify from where you are getting the items.
If you "put" an item into a container, it can originate from a worn location, your main
inventory, or a container.  Regardless of where it starts, the plugin will move it to the
container that you specify.

A "put" request takes a relative location name for the target container and a query that
specifies which items should move into the container.  See "@Gdinv help search@W" for examples
on how queries work and how relative names and locations work.

You may mark containers as "ignored" to prevent dinv from accessing items in those containers.
See the "@Gdinv help ignore@W" helpfile for instructions and examples.

Examples:
  1) Put all aardwolf quest weapons into container 3.bag
     "@Gdinv put 3.bag type weapon keyword aardwolf@W"

  2) Put all potions and pills into container 2.box
     "@Gdinv put 2.box type potion || type pill@W"

  3) Put all portals into container 4.case
     "@Gdinv put 4.case type portal@W"

  4) Put all armor pieces between level 1 and level 100 into container "luggage"
     "@Gdinv put luggage type armor minlevel 1 maxlevel 100@W"
]])

end -- inv.cli.put.examples


inv.cli.store = {}
function inv.cli.store.fn(name, line, wildcards)
  local query = wildcards[1] or ""
  local endTag = inv.tags.new(line)

  dbot.debug("CLI: " .. pluginNameCmd .. " store \"" .. query .. "\"")

  local guardFail = inv.cli.requireReadyStateFor("store")
  if guardFail then return inv.tags.stop(invTagsStore, endTag, guardFail) end

  inv.items.store(query, endTag)
end -- inv.cli.store.fn


function inv.cli.store.usage()
  dbot.print("@W    " .. pluginNameCmd .. " store @G<query>@w")
end -- inv.cli.store.usage


function inv.cli.store.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.store.usage()
  dbot.print(
[[@W
The dinv plugin remembers the container that was most recently used for each item
in the inventory.  This gives you a convenient way to store an item (or items) back
where you got them.  This is very similar to "dinv put ..." but you don't need to
specify the target container.  Each item will go back to the container from which it
was most recently removed.  If an item has never been in a container, "storing" it
will put it in your main inventory.

The query parameter specifies which items will be stored.  See the helpfile at
"@Gdinv help search@W" for examples and more details on using queries.

You may mark containers as "ignored" to prevent dinv from accessing items in those containers.
See the "@Gdinv help ignore@W" helpfile for instructions and examples.

Examples:
  1) Store all items that are level 71
     "@Gdinv store level 71@W"

  2) Store all aardwolf quest items
     "@Gdinv store keyword aardwolf@W"

  3) Store all portals back into their container(s)
     "@Gdinv store type portal@W"
]])

end -- inv.cli.store.examples


inv.cli.keyword = {}
function inv.cli.keyword.fn(name, line, wildcards)
  local operation = wildcards[1] or ""
  local keyword   = wildcards[2] or ""
  local query     = Trim(wildcards[3] or "")
  local endTag    = inv.tags.new(line)

  inv.items.keyword(keyword, operation, query, false, endTag)
end -- inv.cli.keyword.fn


function inv.cli.keyword.usage()
  dbot.print("@W    " .. pluginNameCmd .. " keyword @G[add | remove] <keyword name> <query>@w")
end -- inv.cli.keyword.usage


function inv.cli.keyword.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.keyword.usage()

  dbot.print(
[[@W
Wouldn't it be great if you could easily add or remove keywords from an item?  Now
you can!  Although custom keywords won't be recognized by the mud server, you can use
them with any query used by this plugin.  See "@Gdinv help search@W" for examples and
more details about how to use queries.

Examples:
  1) Add a "@CborrowedFromBob@W" keyword to everything in the container at relative
     location "3.bag".  You can then use the items and when you are ready to give them
     back, you can put them back with "@Gdinv put 3.bag keyword borrowedFromBob@W".
     Nice!
     "@Gdinv keyword add borrowedFromBob rloc 3.bag@W"

  2) Add "@Cfavorite@W" keyword to a level 80 aardwolf sword.
     "@Gdinv keyword add favorite level 80 keyword aardwolf name sword@W"

  3) Remove "@Cfavorite@W" keyword from everything in your inventory.  Remember that an
     empty search query matches everything in your inventory.
     "@Gdinv keyword remove favorite@W"
]])

end -- inv.cli.keyword.examples


inv.cli.set = {}
function inv.cli.set.fn(name, line, wildcards)
  local command = wildcards[1] or ""
  local priority = wildcards[2] or ""
  local level = wildcards[3] or ""
  local endTag = inv.tags.new(line)

  local guardFail = inv.cli.requireReadyStateFor("set")
  if guardFail then return inv.tags.stop(invTagsSet, endTag, guardFail) end

  -- If the user doesn't provide a level, use the current level
  level = tonumber(level) or dbot.gmcp.getLevel()

  dbot.debug("inv.cli.set.fn: command=\"" .. command .. "\", priority=\"" .. priority ..
             "\", level=" .. level)

  if (command == "display") then
    inv.set.display(priority, level, nil, endTag)
  elseif (command == "wear") then
    inv.set.createAndWear(priority, level, inv.set.createIntensity, endTag)
  else
    inv.cli.set.usage()
    inv.tags.stop(invTagsSet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

end -- inv.cli.set.fn


function inv.cli.set.usage()
  dbot.print("@W    " .. pluginNameCmd .. " set @G[display | wear] <priority name> @Y<level>@w")
end -- inv.cli.set.usage()


function inv.cli.set.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.set.usage()
  dbot.print(
[[@W
This plugin can automatically generate equipment sets based on statistic priorities
defined by the user.  This is similar to aardwolf's default "score" value for items.
If you enter "@Gcompare set all@W", you will see aardwolf's default weighting for each
statistic based on your class.

The plugin implements a similar approach, but with many more options.  For example, the
plugin's "priority" feature allows you to define statistic weightings for particular levels
or ranges of levels.  It also supports weightings for item effects such as dual wielding,
iron grip, sanctuary, or regeneration.  You can even indicate how important it is to you to
max out specific stats.  Also, the plugin provides controls that are much more fine-grained
than the default aardwolf implementation.  See "@Gdinv help priority@W" for more details and
examples using stat priorities.

Once you define a group of priorities, you have the ability to create equipment sets based
on those priorities.  The plugin finds the optimal (OK, technically it is near-optimal)
set of items that maximizes your equipment set's score relative to the specified priority.
The plugin accounts for overmaxing stats and at times may use items that superficially
appear to be worse than other items in your inventory.  An item that looks "better" may
be contributing points to stats that are already maxed and alternative "lesser" items may
be more valuable when combined with your other equipment.

If you create a set for your current level, the plugin knows how many bonus stats you
have due to your current spellup.  It can find the exact combination of equipment relative
to your current state so that you don't overmax stats unnecessarily.  If you create one
equipment set while having a normal spellup and a second equipment set after getting a
superhero spellup, chances are high that there would be different equipment in both sets.
However, if you create a set for a level that is either higher or lower than your current
level, then the plugin must make some estimates since it can't know how many stats you would
have due to spells at that level.  It starts by guessing what an "average" spellup should
look like at a specific level.  The plugin also periodically samples your stats as you
play the game and keeps a running weighted average of spell bonuses for each level.  If
you play a style that involves always maintaining an SH spellup, then over time the plugin
will learn to use high estimates for your spell bonuses when it creates a set.  Similarly,
if you don't bother to use spellups, then over time the plugin will learn to use lower
spell bonuses that more accurately reflect your playing style.

The set creation algorithm is smart enough to detect if you have the ability to dual wield
either from aard gloves or naturally via the skill and will base the set accordingly.  It
also checks weapon weights to find the most optimal combination of weapons if dual wield
is available and it is prioritized.

The key point is that we care about maximizing the total *usable* stats in an equipment
set.  Finding pieces that are complementary without wasting points on overmaxed stats is
a process that is well-suited for a plugin -- hence this plugin :)

The "@Cset@W" mode creates the specified set and then either wears the equipment or displays
the results depending on if the "@Cwear@W" or the "@Cdisplay@W" option is specified.  An
optional "@Clevel@W" parameter will create the set targeted at a specific level.  If the
level is not provided, the plugin will default to creating a set for your current level.

For example, consider a scenario where a user creates a priority designed for a primary psi
with at least one melee class and names that priority "@Cpsi-melee@W" (yes, this is what
I normally use -- psis are awesome if you haven't noticed :)).  The following examples
will use this priority.

Examples:
  1) Display what equipment set best matches the psi-melee priority for level 20.  The
     stat summary listed on the last line indicates the cumulative stats for the entire
     set.  This reflects just the stats provided directly by the equipment and it does not
     include any bonuses you may get naturally or via spells.  Also, note the long list
     of effects provided by equipment in this set (haste, regen, etc.).  Each of those
     effects is given a weighting in the psi-melee priority table.
     "@Gdinv set display psi-melee 20@W"

@WEquipment set:   @GLevel  20 @Cpsi-melee
@w
@Y     light@W( 16): @GLevel   1@W "a hallowed light"
@Y      head@W( 40): @GLevel   1@W "@RAardwolf@Y Helm of True Sight@w"
@Y      eyes@W(  8): @GLevel   1@W "@C(@W+@C) @WH@Cowlin@Wg T@Cempes@Wt @C(@W+@C)@w"
@Y      lear@W(  8): @GLevel   1@W "@R(@G+@B) @WMagica Elemental @C(@G+@y)@w"
@Y      rear@W(  8): @GLevel   1@W "@R(@G+@B) @WMagica Elemental @C(@G+@y)@w"
@Y     neck1@W(  8): @GLevel   1@W "@C(@W+@C) @WB@Citin@Wg W@Cind@Ws @C(@W+@C)@w"
@Y     neck2@W(  8): @GLevel   1@W "@C(@W+@C) @WB@Citin@Wg W@Cind@Ws @C(@W+@C)@w"
@Y      back@W(  8): @GLevel   1@W "@C(@W+@C) @WC@Cyclon@We B@Clas@Wt @C(@W+@C)@w"
@Y    medal1@W(  9): @GLevel   1@W "@RA@rcademy @GG@graduation @CM@cedal@w"
@Y    medal2@W(  7): @GLevel   1@W "@YV3 @RA@rardwolf @GS@gupporters @CP@cin@w"
@Y    medal3@W( 19): @GLevel   1@W "V3 @RO@rrder @GO@gf @CT@che @RF@rirst @GT@gier@w"
@Y     torso@W( 17): @GLevel   1@W "@RAardwolf @YBreastplate of Magic Resistance@w"
@Y      body@W(  6): @GLevel   1@W "@ga Tr@ye@wnc@gh C@yo@wa@gt@w"
@Y     waist@W(  8): @GLevel   1@W "@C(@W+@C) @WS@Ctif@Wf B@Creez@We @C(@W+@C)@w "
@Y      arms@W(  8): @GLevel   1@W "@C(@W+@C) @WF@Crost@Wy D@Craf@Wt @C(@W+@C)@w"
@Y    lwrist@W( 12): @GLevel  16@W "@m-=< @BClasp @Wof the @RKeeper@m >=-@w"
@Y    rwrist@W(  8): @GLevel  15@W "thieves' patch"
@Y     hands@W( 30): @GLevel   1@W "@RAardwolf@Y Gloves of Dexterity@w"
@Y   lfinger@W( 31): @GLevel   1@W "@RAardwolf@Y Ring of Regeneration@w"
@Y   rfinger@W( 31): @GLevel   1@W "@RAardwolf@Y Ring of Regeneration@w"
@Y      legs@W(  6): @GLevel   1@W "@C(@W+@C) @WC@Coolin@Wg Z@Cephy@Wr @C(@W+@C)@w"
@Y      feet@W( 65): @GLevel   1@W "@RAardwolf @YBoots of Speed@w"
@Y   wielded@W( 36): @GLevel  20@W "S@we@Wa@wr@Wi@wn@Wg @wB@Wl@wa@Wz@we"
@Y    second@W( 27): @GLevel   8@W "@wa @yFlame@rthrower@w"
@Y     float@W(110): @GLevel   1@W "@RAardwolf @YAura of Sanctuary@w"
@Y     above@W( 14): @GLevel   1@W "@RAura @Yof @GTrivia@w"
@Y    portal@W(  3): @GLevel   5@W "@RA@rura @Ro@rf @Bt@bhe @BS@bage@w"
@Y  sleeping@W(  0): @GLevel   1@W "V3 @RTrivia @gSleeping Bag@w"
@w
@WAve Sec  HR  DR Int Wis Lck Str Dex Con Res HitP Mana Move Effects
@G 30@W @G  4@W @G114@W @G205@W @G 20@W @G 37@W @G 71@W @G 22@W @G 24@W @G 13@W @G103@W @G 405@W @G 235@W @G 385@W haste regeneration sanctuary dualwield@W detectgood detectevil detecthidden detectinvis detectmagic@W

  2) Display the psi-melee equipment set for my current level (which was 211 at the
     time I ran this example -- 201 + 10 levels as a T1 tier bonus)
     "@Gdinv set display psi-melee@W"

@WEquipment set:   @GLevel 211 @Cpsi-melee
@w
@Y     light@W( 59): @GLevel 200@W "@cShining Aqua Light@w"
@Y      head@W( 56): @GLevel 200@W "@R(@YO@R)@YCirclet @Rof@Y Autumn Leaves@R(@YO@R)@w"
@Y      eyes@W( 52): @GLevel 201@W "forest vision"
@Y      lear@W( 41): @GLevel 200@W "@wa @YS@ymall @RR@ruby @YEar@yring@w"
@Y      rear@W( 50): @GLevel 211@W "@m@-@-@YGe@ynie's Magical Ear@Yring@m@-@-@w"
@Y     neck1@W( 42): @GLevel 201@W "a protective cloak skinned from a leaf scorpionfish"
@Y     neck2@W( 40): @GLevel 201@W "a protective cloak skinned from a salamander cocoon"
@Y      back@W( 45): @GLevel 201@W "@MP@mandora@w'@ms @R[@GBox@R]@w"
@Y    medal1@W( 11): @GLevel   1@W "@RA@rcademy @GG@graduation @CM@cedal@w"
@Y    medal2@W( 12): @GLevel   1@W "@YV3 @RA@rardwolf @GS@gupporters @CP@cin@w"
@Y    medal3@W( 23): @GLevel   1@W "V3 @RO@rrder @GO@gf @CT@che @RF@rirst @GT@gier@w"
@Y     torso@W( 83): @GLevel 201@W "@RAardwolf @YBreastplate of Magic Resistance@w"
@Y      body@W( 49): @GLevel 200@W "-@m=@W*@m)@WA @MP@mure @Ma@mnd @MT@mrue @WHeart@m(@W*@m=@W-@w"
@Y     waist@W( 46): @GLevel 200@W "a @YS@ytu@wdd@yed @YL@yea@wth@yer @YB@ye@wl@yt@w"
@Y      arms@W(101): @GLevel 211@W "@RAardwolf@Y Bracers of Iron Grip@w"
@Y    lwrist@W( 38): @GLevel 200@W "@rCuff @wof @B@-@D{@C*@W}@rSou@Rls@W{@C*@D}@B@-@w"
@Y    rwrist@W( 37): @GLevel 200@W "a twig bracelet"
@Y     hands@W( 73): @GLevel 211@W "@RAardwolf@Y Gloves of Dexterity@w"
@Y   lfinger@W( 44): @GLevel 200@W "@YG@yold @WS@wignet of @CL@cocksley@w"
@Y   rfinger@W( 44): @GLevel 200@W "a ring of the Dark Eight@w"
@Y      legs@W( 44): @GLevel 200@W "@R(FAKE) @GXeno's @YKnickers @cof @CAwesomeness@w"
@Y      feet@W( 52): @GLevel 200@W "@g.o@GO@go.@BDra@Gbani Bo@Blers @MSkorni @g.o@GO@go.@w"
@Y   wielded@W(666): @GLevel 211@W "@YAxe of @RAardwolf@w"
@Y    second@W(709): @GLevel 211@W "@YDagger of @RAardwolf@w"
@Y     float@W( 45): @GLevel 201@W "a @YGolden Halo@w"
@Y     above@W( 18): @GLevel   1@W "@RAura @Yof @GTrivia@w"
@Y    portal@W( 28): @GLevel 180@W "the @YTiger @Wof @CKai@w"
@Y  sleeping@W(  0): @GLevel   1@W "V3 @RTrivia @gSleeping Bag@w"
@w
@WAve Sec  HR  DR Int Wis Lck Str Dex Con Res HitP Mana Move Effects
@G633@W @G633@W @G501@W @G643@W @G 95@W @G111@W @G138@W @G 73@W @G 42@W @G 33@W @G436@W @G1532@W @G 657@W @R-404@W dualwield irongrip@W

  3) I also use an "@Cenchanter@W" priority group to boost int, wis, and luck when I
     want to enchant something.  To wear the equipment set associated with this priority
     I would use the command given below.  It automatically removes any currently worn
     items that are not in the new set and stores those items in their respective "home"
     containers.  It then pulls the new items from wherever they are stored and wears
     them.  Easy peasy.
     "@Gdinv set wear enchanter@W"
]])

end -- inv.cli.set.examples


inv.cli.weapon = {}
function inv.cli.weapon.fn(name, line, wildcards)
  local priority = wildcards[1] or ""
  local damTypes = wildcards[2] or ""
  local endTag = inv.tags.new(line)

  local guardFail = inv.cli.requireReadyStateFor("weapon")
  if guardFail then return inv.tags.stop(invTagsSet, endTag, guardFail) end

  if (priority == "next") then
    inv.weapon.next(endTag)
  else
    inv.weapon.use(priority, damTypes, endTag)
  end -- if

end -- inv.cli.weapon.fn


function inv.cli.weapon.usage()
  dbot.print("@W    " .. pluginNameCmd .. " weapon @G[next | <priority name> <damType list>]@w")
end -- inv.cli.weapon.usage()


function inv.cli.weapon.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.weapon.usage()
  dbot.print(
[[@W
Equipment sets can specify which damage types are allowed on weapons in the set.  However,
it would be tedious to create multiple priorities to target specific damage types.  The
"@Cweapon@W" mode provides a simple and convenient way to indicate which damage types you
want to use (or do *not* want to use) as an extension to an existing priority.  See the
helpfile at "@Gdinv help priority@W" for details on how to create and use a priority.
@Y
NOTE: The basic identify command does not report damage types for unowned items.  Dinv will
      not be able to find and use unowned weapons based on their damage type unless one of
      these conditions is met:

      1) You have the identify wish
      2) Dinv identified your weapons in Hester's room at Aylor
      3) Your weapon is an owned item (fortunately quest weapons are owned)

      The examples below assume you have damage type information available for the weapons
      you are using.  Run "@Gdinv search type weapon@Y" and look at the "Dam Type" column to
      see which of your weapons have known damage types.
@W
The first step is to specify which damage types you want to allow within a particular
priority by providing a list of specific damage types (e.g., "pierce" or "mental") and/or
damage type groups (e.g., "all", "physical", or "magic").  The plugin will determine the
optimal equipment set (including weapons) that matches the damage type requirements and
then wear the items in that equipment set.

Once the weapon damage types are specified, you may use the "@Gdinv weapon next@W" command
to rotate through the types.  Each time the "next" command is given the plugin will remove
one of the available damage types from the originally provided list and generate and wear
the best possible equipment set that is compatible with the remaining damage types.  The
plugin's algorithm starts with highest scoring equipment set and then removes the damage
type of that set's primary weapon to find the next best equipment set.

In most cases, using the "@Cweapon@W" mode will just swap your weapons (and possibly your
shield and/or held item if that's your priority's preference).  However, it is possible that
the optimal equipment set for a particular weapon also involves changing a few other pieces
of equipment.  Remember that this plugin always looks at an entire set's score to gauge how
good a set is and the items in the "best" set will vary over time depending on your spellup.

Examples!
  1) Oh noes!  You are at The Demon's Flight and you need a weapon that does pierce damage.
     You are using the psi-melee priority (because you are awesome enough to be a psi) and
     you need to swap weapons -- quick!
     @Gdinv weapon psi-melee pierce@W

  2) You are pupping at the Earth Lords and run into one of those annoying void warriors
     that are immune to all magical damage.  Let's tell the plugin to only use weapons with
     physical damage types.  Because I'm lazy, and "physical" is such a long word *grin*
     you can also abbreviate it to "phys" in the example below.
     @Gdinv weapon psi-melee physical@W

  3) Same as the above example, but you are fighting a mob immune to physical damage
     @Gdinv weapon psi-melee magic@W

  4) You are fighting a mob that seems to be immune to everything.  Let's try to find a
     weapon that will work for you.
     @Gdinv weapon psi-melee all@W

     If the first weapon set works, great :)  If not, eliminate the damage type found on
     your primary weapon, create a set with the remaining damage types, and try again.
     @Gdinv weapon next@W

     You can keep calling @Gdinv weapon next@W" until you run out of possible weapon set
     combinations.  At that point, you may want to flee :p

  5) You are a 1337 PK-er and are fighting your arch-enemy clan composed of vampires,
     eldar, and giants.  You want to target their vulnerabilities so you turn to dinv.
     @Gdinv weapon psi-melee light slash mental@W

  6) You are fighting a mob that you think is vulnerable to shadow, poison, and all physical
     damage types.  Ok, that isn't really a realistic scenario but I'm a little too tired to
     make all these examples realistic tonight...
     @Gdinv weapon psi-melee phys shadow poison@W
     @Gdinv weapon next@W

]])

end -- inv.cli.weapon.examples


inv.cli.priority = {}
function inv.cli.priority.fn(name, line, wildcards)
  local command       = Trim(wildcards[1] or "")
  local priorityName1 = Trim(wildcards[2] or "")
  local priorityName2 = Trim(wildcards[3] or "")
  local endTag        = inv.tags.new(line)

  dbot.debug("inv.cli.priority.fn: command=\"" .. command .. "\", name1=\"" .. priorityName1 ..
             "\", name2=\"" .. priorityName2 .. "\"")

  if (not inv.init.initializedActive) then
    dbot.info("Skipping priority request: plugin is not yet initialized (are you AFK or sleeping?)")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_UNINITIALIZED)
  end -- if

  if (command == "list") then
    inv.priority.list(endTag)

  elseif (command == "display") then
    inv.priority.display(priorityName1, endTag)

  elseif (command == "compare") then
    inv.priority.compare(priorityName1, priorityName2, endTag)

  elseif (command == "create") then
    inv.priority.create(priorityName1, endTag)

  elseif (command == "delete") then
    inv.priority.delete(priorityName1, endTag)

  elseif (command == "clone") then
    inv.priority.clone(priorityName1, priorityName2, true, endTag)

  elseif (command == "copy") then
    inv.priority.copy(priorityName1, endTag)

  elseif (command == "paste") then
    inv.priority.paste(priorityName1, endTag)

  else
    inv.cli.priority.usage()
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

end -- inv.cli.priority.fn


function inv.cli.priority.fn2(name, line, wildcards)
  local command      = Trim(wildcards[1] or "")
  local priorityName = Trim(wildcards[2] or "")
  local editFields   = Trim(wildcards[3] or "")
  local level        = tonumber(wildcards[3] or "")
  local endTag       = inv.tags.new(line)

  dbot.debug("inv.cli.priority.fn2: command=\"" .. command .. "\", priority=\"" .. priorityName ..
             "\", level=\"" .. (level or "nil") .. "\"")

  if (not inv.init.initializedActive) then
    dbot.info("Skipping priority request: plugin is not yet initialized (are you AFK or sleeping?)")
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_UNINITIALIZED)
  end -- if

  if (command == "edit") then
    local useAllFields

    if (editFields == "full") then
      useAllFields = true
    elseif (editFields == "") then
      useAllFields = false
    else
      inv.cli.priority.usage()
      return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
    end -- if

    inv.priority.edit(priorityName, useAllFields, false, endTag)

  elseif (command == "split") then
    inv.priority.split(priorityName, level, endTag)

  elseif (command == "join") then
    inv.priority.join(priorityName, level, endTag)

  else
    inv.cli.priority.usage()
    return inv.tags.stop(invTagsPriority, endTag, DRL_RET_INVALID_PARAM)
  end -- if

end -- inv.cli.priority.fn2


function inv.cli.priority.usage()
  dbot.print("@W    " .. pluginNameCmd ..
             " priority @G[list | display | create | clone | delete | edit | copy | paste | compare] " ..
             "@Y<name 1> <name 2>@w")
end -- inv.cli.priority.usage


function inv.cli.priority.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.priority.usage()

  dbot.print(
[[@W
Aardwolf provides a system to "score" an item relative to how important particular statistics
are you to.  Run "@Gcompare set@W" to see the current scoring weighting for your character.
This is a great system and it allows you to customize how important particular statistics are
to you and your particular playing style.

However, this system has several limitations.  This plugin addresses those limitations by
giving users the ability to implement one or more customizable "priority" groups.  Extensions
to the mud's scoring system include:
  1) Entire equipment sets are scored collectively.  Knowing how a particular item is scored is
     great, but it doesn't show the entire picture.  What you really care about is how many stats
     or bonuses are available by a combination of your equipment.
  2) Stat bonuses are capped at each level.  If you only look at individual item scores, it can
     be very hard to find an optimal set of equipment that doesn't waste stats that will be over
     the max and ignored by the mud.  The plugin's priority implementation uses a simulated
     annealing algorithm to search through combinations of your equipment to find the optimal (or
     near-optimal) set of items that scores highest for your particular priorities.
  3) The "optimal" equipment at any given time is highly dependent on how many bonuses a character
     has due to spells at that moment.  If you get a great spellup, changes are high that you will
     want to use different equipment than if you have a normal spellup because the better spellup
     may push some stats over the max and you are wasting opportunities to bump up other stats
     with different equipment.
  4) The plugin's priority implementation allows you to specify your priorities at specific levels
     or a range of levels.  For example, a primary spellcaster may want to emphasize str and dex
     more at lower levels and emphasize int and luck more at higher levels.  You might also give
     the "haste" effect a high priority at lower levels and a lower priority once you have access
     to the haste spell.  Your priorities will change relative to your level and this plugin
     gives you that opportunity.
  5) We provide the ability to prioritize item effects such as sanctuary, haste, or detect invis.
  6) We also allow you to specify the importance of the dual wield and irongrip effects given
     by aard gloves and bracers.
  7) You can prioritize the defensive bonus provided by a shield.
  8) You can prioritize the value of maxing a particular stat.  For example, if a navigator is
     one stat point away from getting access to another bypassed area, that navigator could bump
     up the value of maxing that stat.
  9) You can also prioritize the damage of primary hand weapons and secondary hand weapons
     separately.  This gives you a lever to control how important dual wielding is to you.
 10) The plugin provides much more fine-grained control of specific stats and resists than what
     is found in the default mud's scoring system.

The plugin includes very crude priorities for each aardwolf class that have names matching the
name of the class ("psi", "mage", "warrior", "ranger", "paladin", "thief", "cleric").  These
default priorities match the "score" priorities found by running "@Gcompare set@W" on aard for
a given class.  You will almost certainly want to tweak (or massively overhaul!) these, but they
give you a rough idea for a starting point.

NOTE: Editing a priority will invalidate any previous equipment set analysis based on that
priority.  See "@Gdinv help analyze@W" for instructions on recreating a set analysis.  In most
instances, you will simply run "@Gdinv analyze create <priority name>@W".

Examples:
  1) List all existing priorities defined for the plugin
     "@Gdinv priority list@W"

  2) Clone an existing priority.  In this example we make a copy of the default "warrior" priority
     and name it "myAwesomeWarrior".
     "@Gdinv priority clone warrior myAwesomeWarrior@W"

  3) Display the "psi-melee" priority bundled with the plugin.  This is intended for a primary
     psi with at least one melee class.  You may or may not agree with these priorities.  That's
     why this plugin gives you the ability to tweak things to your heart's content :)  This
     priority defines 6 different level ranges with different priorities at each range.
     "@Gdinv priority display psi-melee@W"

@WPriority: "@Cpsi-melee@W"

@W    MinLevel      1     51    101    131    171    201
    MaxLevel    @W 50    100    130    170    200    291
@C
@C         str@w   1.00   1.00   0.80@y   0.70   0.70   0.50@W  : @cValue of 1 point of the strength stat
@C         int@w   0.80   1.00   1.00   1.00   1.00   1.00@W  : @cValue of 1 point of the intelligence stat
@C         wis@y   0.70@w   0.80   0.90   1.00   1.00   1.00@W  : @cValue of 1 point of the wisdom stat
@C         dex@w   0.80@y   0.50   0.60   0.50@r   0.40   0.40@W  : @cValue of 1 point of the dexterity stat
@C         con@r   0.20   0.20   0.40   0.40   0.40   0.25@W  : @cValue of 1 point of the constitution stat
@C        luck@w   1.00   1.00   1.00   1.00   1.00   1.00@W  : @cValue of 1 point of the luck stat
@C         dam@w   0.90   0.90   0.85   0.85   0.85   0.80@W  : @cValue of 1 point of damroll
@C         hit@w   0.85   0.80@y   0.75@w   0.85   0.85   0.80@W  : @cValue of 1 point of hitroll
@C      avedam@w   1.00   1.00   1.00   1.00   1.00   1.00@W  : @cValue of 1 point of primary weapon ave damage
@C  offhandDam@r   0.33   0.40@y   0.50   0.60   0.70@w   0.85@W  : @cValue of 1 point of offhand weapon ave damage
@C          hp@r   0.02   0.01   0.01   0.01   0.01   0.01@W  : @cValue of 1 hit point
@C        mana@r   0.01   0.01   0.01   0.01   0.01   0.01@W  : @cValue of 1 mana point
@C   sanctuary@G  50.00  10.00  10.00  10.00  10.00   5.00@W  : @cValue placed on the sanctuary effect
@C       haste@G  20.00   5.00@g   2.00   2.00   2.00   2.00@W  : @cValue placed on the haste effect
@C      flying@G   5.00@g   4.00   2.00@w   1.00   1.00   1.00@W  : @cValue placed on the flying effect
@C       invis@G  10.00   5.00@g   3.00@w   1.00   1.00   1.00@W  : @cValue placed on the invisible effect
@Cregeneration@G   5.00   5.00   5.00   5.00   5.00@g   2.00@W  : @cValue placed on the regeneration effect
@C detectinvis@g   4.00   4.00   2.00   2.00   2.00   2.00@W  : @cValue placed on the detect invis effect
@Cdetecthidden@g   3.00   3.00   2.00   2.00   2.00   2.00@W  : @cValue placed on the detect hidden effect
@C  detectevil@g   2.00   2.00   2.00   2.00   2.00   2.00@W  : @cValue placed on the detect evil effect
@C  detectgood@g   2.00   2.00   2.00   2.00   2.00   2.00@W  : @cValue placed on the detect good effect
@C   dualwield@G  20.00@R   0.00   0.00   0.00   0.00   0.00@W  : @cValue of an item's dual wield effect
@C    irongrip@g   2.00   3.00@G  20.00  20.00  25.00  30.00@W  : @cValue of an item's irongrip effect
@C      shield@G   5.00   5.00  10.00  20.00  25.00  40.00@W  : @cValue of a shield's damage reduction effect
@C    allmagic@r   0.03   0.03   0.05   0.05   0.05   0.05@W  : @cValue of 1 point in each magical resist type
@C     allphys@r   0.03   0.05   0.10   0.10   0.10   0.10@W  : @cValue of 1 point in each physical resist type
@C      maxint@R   0.00   0.00   0.00   0.00@G   5.00  20.00@W  : @cValue of hitting a level's intelligence ceiling
@C      maxwis@R   0.00   0.00   0.00   0.00@G   5.00  20.00@W  : @cValue of hitting a level's wisdom ceiling
@C     maxluck@R   0.00   0.00   0.00   0.00@G   5.00  20.00@W  : @cValue of hitting a level's luck ceiling
@W
  4) Create a new priority from scratch.  This will pop up a window populated with a single level
     range (1 - 291) and values of 0 for each possible priority field.  You can break the level
     range into multiple ranges by adding additional columns and ensuring that each column's min
     and max level fields do not overlap with another column.  Once you enter values for each
     field, hit the "Done!" button to save your work.
     "@Gdinv priority create sillyTankMage@W"

  5) Yeah, that tank mage thing was probably too silly.  Let's delete it.
     "@Gdinv priority delete sillyTankMage@W"

  6) Edit an existing priority.  This could be something that you cloned, something you made from
     scratch, or even a modified default priority.  This example does not use the "full" mode and
     only lists fields that have a non-zero value.  It also does not include descriptions for each
     priority field.  That makes things more compact and easier to see.
     "@Gdinv priority edit psi-no-melee@W"

  7) Edit a priority with the "full" mode.  This shows everything -- including fields that only
     have a priority of zero.  It also shows a description for each field.  If you use the "full"
     mode on a large priority, you may need to resize your edit window to see everything.
     "@Gdinv priority edit mage full@W"

  8) Use an external editor to modify a priority.  You can copy the priority data to the system
     clipboard to make it easy to transfer the priority to your own editor.
     "@Gdinv priority copy psi-melee@W"

  9) Paste priority data from the system clipboard and use that data to either create a new
     priority (if it doesn't exist yet) or update an existing priority.  This is convenient if you
     used an external editor to modify the priority data and you want to import that data back into
     the plugin.
     "@Gdinv priority paste myThief@W"

 10) Copy/paste a priority to make a duplicate.  Yes, this is essentially the "@Cclone@W" mode,
     but it shows off what you can do with "@Ccopy@W" and "@Cpaste@W".
     "@Gdinv priority copy mage@W"
     "@Gdinv priority paste myMage@W"

 11) Compare the stat differences at all levels for the equipment sets generated by two different
     priorities.  This will generate a big report that I didn't include here because this helpfile
     is already enormous :)  If you have not already performed a full analysis of both priorities
     you will be prompted to do so before the comparison can execute.  The output shown below is
     just a snippet.  For my equipment at level 11, switching from the "psi" to the "psi-melee"
     priority loses my shield and a little hitroll, con, and resists.  However, it gives me a lot
     more weapon damage and damroll, a little more int, and the regeneration effect (it must use a
     ring of regen while the "psi" priority doesn't.)
     "@Gdinv priority compare psi psi-melee@W"

@WSwitching from priority "@Gpsi@W" to priority "@Gpsi-melee@W" would result in these changes:

@W            Ave  Sec  HR  DR Int Wis Lck Str Dex Con Res HitP Mana Move Effects
@WLevel  11: @G  23@W @G   4@W @R -6@W @G 26@W @G  2@W   0   0   0   0 @R -4@W @R -2@W    0    0    0 @Gregeneration@W @Rshield@W
@WLevel  12: @G  23@W @G   4@W @R -6@W @G 26@W @G  2@W   0   0   0   0 @R -4@W @R -2@W    0    0    0 @Gregeneration@W @Rshield@W
@WLevel  13: @G  23@W @G   4@W @R -6@W @G 26@W @G  2@W   0   0   0   0 @R -4@W @R -2@W    0    0    0 @Gregeneration@W @Rshield@W
@WLevel  14: @G  23@W @G   4@W @R -6@W @G 26@W @G  2@W   0   0   0   0 @R -4@W @R -2@W    0    0    0 @Gregeneration@W @Rshield@W
@WLevel  15: @G  23@W @G   4@W @R -3@W @G 22@W   0   0   0   0   0 @R -4@W @R -2@W    0    0    0 @Gregeneration@W @Rshield@W
@WLevel  16: @G  23@W @G   4@W @R -9@W @G 32@W   0   0   0   0   0 @R -4@W   0    0    0    0 @Gregeneration@W @Rshield@W
@WLevel  17: @G  23@W @G   4@W @R -9@W @G 32@W   0   0   0   0   0 @R -4@W   0    0    0    0 @Gregeneration@W @Rshield@W
@WLevel  18: @G  23@W @G   4@W @R -9@W @G 32@W   0   0   0   0   0 @R -4@W   0    0    0    0 @Gregeneration@W @Rshield@W
@WLevel  19: @G  23@W @G   4@W @R -9@W @G 32@W   0   0   0   0   0 @R -3@W   0    0    0    0 @Gregeneration@W @Rshield@W
]])

end -- inv.cli.priority.examples


inv.cli.snapshot = {}
function inv.cli.snapshot.fn(name, line, wildcards)
  local command      = wildcards[1] or ""
  local snapshotName = wildcards[2] or ""
  local endTag       = inv.tags.new(line)

  dbot.debug("inv.cli.snapshot: command=\"" .. command .. "\", name=\"" .. snapshotName .. "\"")

  if (not inv.init.initializedActive) then
    dbot.info("Skipping snapshot request: plugin is not yet initialized (are you AFK or sleeping?)")
    return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_UNINITIALIZED)
  end -- if

  if (command == "create") then
    inv.snapshot.add(snapshotName, endTag)

  elseif (command == "delete") then
    inv.snapshot.remove(snapshotName, endTag)

  elseif (command == "list") then
    inv.snapshot.list(endTag)

  elseif (command == "display") then
    inv.snapshot.display(snapshotName, endTag)

  elseif (command == "wear") then

    if dbot.gmcp.statePreventsActions() then
      dbot.info("Skipping snapshot wear request: character's state does not allow actions")
      return inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_NOT_ACTIVE)
    end -- if

    inv.snapshot.wear(snapshotName, endTag)

  else
    inv.cli.snapshot.usage()
    inv.tags.stop(invTagsSnapshot, endTag, DRL_RET_INVALID_PARAM)
  end -- if

end -- inv.cli.snapshot.fn


function inv.cli.snapshot.usage()
  dbot.print("@W    " .. pluginNameCmd ..
             " snapshot @G[create | delete | list | display | wear] @Y<snapshot name>")
end -- inv.cli.snapshot.usage


function inv.cli.snapshot.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.snapshot.usage()

  dbot.print(
[[@W
It's quite easy to take an equipment "snapshot" consisting of everything you are wearing
at the time of the snapshot.  You can then easily re-wear the items contained in the
snapshot at a later time.  My guess is that most people will want to use automatically
generated equipment sets (see "@Gdinv help set@W") in most cases.  However, it could also
be very convenient to explicitly manage what is in a particular set and that is where
snapshots come into play.

If you wear a snapshot, it will remove any currently worn items that are not in the
snapshot and put them away in each item's "home" container (the container where the item
was most recently removed).  If a removed item has never been in a container, the plugin
will put it in your main inventory.

Examples!
  1) Take a snapshot of what you currently are wearing and name it "myAwesomeSnapshot"
     "@Gdinv snapshot create myAwesomeSnapshot@W"

  2) List existing snapshots that you have previously taken
     "@Gdinv snapshot list@W"

  3) Display what equipment is in a particular snapshot.  The output shown below is in
     the same format that you would see with a regular automatically generated set.  The
     main difference is that each item's score (the number in parentheses) is 0 here because
     we are not scoring the item relative to a priority.  We are just showing what items
     would be present in the snapshot.  See the helpfile at "@Gdinv help set@W" for details.
     "@Gdinv snapshot display myAwesomeSnapshot@W"

@WEquipment set: "@CmyAwesomeSnapshot@W"
@w
@Y     light@W(  0): @GLevel 200@W "@cShining Aqua Light@w"
@Y      head@W(  0): @GLevel 200@W "@R(@YO@R)@YCirclet @Rof@Y Autumn Leaves@R(@YO@R)@w"
@Y      eyes@W(  0): @GLevel 200@W "/@D[_]@W-@D[_]@W @DHorn@W-@DRimmed @WGlasses@w"
@Y      lear@W(  0): @GLevel 200@W "@wa @YS@ymall @RR@ruby @YEar@yring@w"
@Y      rear@W(  0): @GLevel 211@W "@m@-@-@YGe@ynie's Magical Ear@Yring@m@-@-@w"
@Y     neck1@W(  0): @GLevel 201@W "a protective cloak skinned from a leaf scorpionfish"
@Y     neck2@W(  0): @GLevel 201@W "a protective cloak skinned from a salamander cocoon"
@Y      back@W(  0): @GLevel 201@W "@MP@mandora@w'@ms @R[@GBox@R]@w"
@Y    medal1@W(  0): @GLevel   1@W "@RA@rcademy @GG@graduation @CM@cedal@w"
@Y    medal2@W(  0): @GLevel   1@W "@YV3 @RA@rardwolf @GS@gupporters @CP@cin@w"
@Y    medal3@W(  0): @GLevel   1@W "V3 @RO@rrder @GO@gf @CT@che @RF@rirst @GT@gier@w"
@Y     torso@W(  0): @GLevel 201@W "@RAardwolf @YBreastplate of Magic Resistance@w"
@Y      body@W(  0): @GLevel 200@W "-@m=@W*@m)@WA @MP@mure @Ma@mnd @MT@mrue @WHeart@m(@W*@m=@W-@w"
@Y     waist@W(  0): @GLevel 200@W "a @YS@ytu@wdd@yed @YL@yea@wth@yer @YB@ye@wl@yt@w"
@Y      arms@W(  0): @GLevel 211@W "@RAardwolf@Y Bracers of Iron Grip@w"
@Y    lwrist@W(  0): @GLevel 200@W "@rCuff @wof @B@-@D{@C*@W}@rSou@Rls@W{@C*@D}@B@-@w"
@Y    rwrist@W(  0): @GLevel 200@W "a twig bracelet"
@Y     hands@W(  0): @GLevel 211@W "@RAardwolf@Y Gloves of Dexterity@w"
@Y   lfinger@W(  0): @GLevel 200@W "a ring of the Dark Eight@w"
@Y   rfinger@W(  0): @GLevel 200@W "a ring of the Dark Eight@w"
@Y      legs@W(  0): @GLevel 200@W "@R(FAKE) @GXeno's @YKnickers @cof @CAwesomeness@w"
@Y      feet@W(  0): @GLevel 200@W "@g.o@GO@go.@BDra@Gbani Bo@Blers @MSkorni @g.o@GO@go.@w"
@Y   wielded@W(  0): @GLevel 211@W "@YAxe of @RAardwolf@w"
@Y    second@W(  0): @GLevel 211@W "@YDagger of @RAardwolf@w"
@Y     float@W(  0): @GLevel 201@W "a @YGolden Halo@w"
@Y     above@W(  0): @GLevel   1@W "@RAura @Yof @GTrivia@w"
@Y    portal@W(  0): @GLevel 180@W "the @YTiger @Wof @CKai@w"
@Y  sleeping@W(  0): @GLevel   1@W "V3 @RTrivia @gSleeping Bag@w"
@w
@WAve Sec  HR  DR Int Wis Lck Str Dex Con Res HitP Mana Move Effects
@G633@W @G633@W @G500@W @G642@W @G121@W @G 99@W @G129@W @G 62@W @G 44@W @G 32@W @G407@W @G1832@W @G 757@W @R-604@W dualwield irongrip @W

  4) Wear a snapshot named "my_level_171_set"
     "@Gdinv snapshot wear my_level_171_set@W"

  5) Delete a snapshot named myEqIs1337
     "@Gdinv snapshot delete myEqIs1337@W"
]])

end -- inv.cli.snapshot.examples


inv.cli.analyze = {}
inv.cli.analyzePkg = nil
function inv.cli.analyze.fn(name, line, wildcards)
  local command      = wildcards[1] or ""
  local priorityName = wildcards[2] or ""
  local wearableLocs = wildcards[3] or ""
  local expandedLocs = ""
  local skip         = tonumber(wildcards[3] or "")
  local endTag       = inv.tags.new(line, "Analysis results", nil, inv.tags.cleanup.timed)
  local retval

  dbot.debug("inv.cli.analyze.fn: priority=\"" .. priorityName .. "\", loc=\"" .. wearableLocs .. "\"")

  local guardFail = inv.cli.requireActiveStateFor("analyze")
  if guardFail then return inv.tags.stop(invTagsAnalyze, endTag, guardFail) end

  -- If the user gave a wearable location, check if it is actually valid.  We also support the
  -- user giving us wearable types (e.g., "neck") in addition to wearable locations (e.g., "neck1 neck2").
  if (wearableLocs ~= "") and (skip == nil) then
    for loc in wearableLocs:gmatch("%S+") do
      if inv.items.isWearableLoc(loc) then
        expandedLocs = expandedLocs .. " " .. loc
      elseif inv.items.isWearableType(loc) then
        expandedLocs = expandedLocs .. " " .. inv.items.wearableTypeToLocs(loc)
      else
        dbot.warn("inv.cli.analyze.fn: Invalid wearable type or location \"@R" .. loc .. "@W\"")
        dbot.info("Run \"@Gwearables@W\" to see keywords for valid wearable locations.")
        return inv.tags.stop(invTagsAnalyze, endTag, DRL_RET_INVALID_PARAM)
      end -- if
    end -- for
  end -- if

  if (skip ~= nil) then
    if (skip < 1) then
      skip = 1
    elseif (skip > 200) then
      skip = 200
    end -- if
  end -- if

  if (command == "create") then
    if (inv.cli.analyzePkg ~= nil) then
      dbot.info("Skipping analysis of priority \"@C" .. priorityName ..
                "@W\": another analysis is in progress")
      return inv.tags.stop(invTagsAnalyze, endTag, DRL_RET_BUSY)
    else
      inv.cli.analyzePkg              = {}
      inv.cli.analyzePkg.priorityName = priorityName
      inv.cli.analyzePkg.wearableLocs = expandedLocs
      inv.cli.analyzePkg.skip         = skip or 1
      inv.cli.analyzePkg.intensity    = inv.set.analyzeIntensity --TODO: let user specify this?
      inv.cli.analyzePkg.endTag       = endTag

      wait.make(inv.cli.analyzeCR)
    end -- if

  elseif (command == "delete") then
    retval = inv.analyze.delete(priorityName)
    inv.tags.stop(invTagsAnalyze, endTag, retval)

  elseif (command == "display") then
    inv.analyze.display(priorityName, expandedLocs, endTag)

  else
    inv.cli.analyze.usage()
    inv.tags.stop(invTagsAnalyze, endTag, DRL_RET_INVALID_PARAM)
  end -- if

end -- inv.cli.analyze.fn


function inv.cli.analyze.fn2(name, line, wildcards)
  local endTag = inv.tags.new(line)

  if (not inv.init.initializedActive) then
    dbot.info("Skipping analyze request: plugin is not yet initialized (are you AFK or sleeping?)")
    return inv.tags.stop(invTagsAnalyze, endTag, DRL_RET_UNINITIALIZED)
  end -- if

  local retval = inv.analyze.list()

  inv.tags.stop(invTagsAnalyze, endTag, retval)
end -- inv.cli.analyze.fn2


function inv.cli.analyzeCR()
  local retval
  local tierLevel = 10 * dbot.gmcp.getTier()

  if (inv.cli.analyzePkg == nil) then
    dbot.error("inv.cli.analyzeCR: analyze package is nil!")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local priorityName = inv.cli.analyzePkg.priorityName or "nil"
  local wearableLocs = inv.cli.analyzePkg.wearableLocs
  local skip         = inv.cli.analyzePkg.skip
  local intensity    = inv.cli.analyzePkg.intensity
  local endTag       = inv.cli.analyzePkg.endTag

  dbot.info("Performing equipment analysis for priority \"@C" .. priorityName .. "@W\"...")
  dbot.info("This analysis can potentially take several minutes.  Be patient!\n")

  local resultData = dbot.callback.new()
  retval = inv.analyze.sets(priorityName, 1 + tierLevel, skip, resultData, intensity)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.cli.analyzeCR: Failed to analyze sets: " .. dbot.retval.getString(retval))
  else
    -- Wait until the analysis is complete
    retval = dbot.callback.wait(resultData, inv.analyze.timeoutThreshold)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.cli.analyzeCR: Analysis of set failed: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  if (retval == DRL_RET_SUCCESS) then
    retval = inv.analyze.display(priorityName, wearableLocs, nil)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.cli.analyzeCR: analysis display failed: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  inv.cli.analyzePkg = nil

  return inv.tags.stop(invTagsAnalyze, endTag, retval)
end -- inv.cli.analyzeCR


function inv.cli.analyze.usage()
  dbot.print("@W    " .. pluginNameCmd ..
             " analyze @G[list | create | delete | display] <priority name> @Y<positions | skip#>@w")
end -- inv.cli.analyze.usage


function inv.cli.analyze.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.analyze.usage()

  dbot.print(
[[@W
The plugin has the ability to analyze your equipment relative to a priority group.  This
analysis identifies the "best" equipment for you at each wearable location at each level.
Creating a full analysis takes roughly 60 seconds (I'm using a 5-year old mac mini running
wine -- your times could be better or worse depending on your hardware.)

You can "@Clist@W" all of the analyses that have been created.  If an analysis exists for all
200 levels available to your character, the analysis is shown in @Ggreen@W.  If one or more
levels does not yet have an equipment set (e.g., maybe you used "@Gdinv set ...@W" to create one
 set but you didn't perform a full analysis) then that analysis name is shown in @Yyellow@W.

Once you "@Ccreate@W" the analysis data, you can "@Cdisplay@W" it quickly without regenerating
all of the data.  If you add new equipment to your inventory, you should recreate the analysis
to pick up any changes due to the new equipment.  Note that the "@Gdinv set ...@W" options
automatically use all of your equipment when creating sets but we don't proactively create new
sets for all 200 levels unless you explicitly request that via "@Gdinv analyze create [name]@W".

If you edit a priority (e.g., "@Gdinv priority edit [name]@W") then any analysis created with
the previous version of that priority is invalid.  As a result, the plugin will erase any stale
analysis when a priority changes and you will need to create it again using the updated version
of the priority.

You have the option of displaying equipment results for one or more specific wearable locations.
For example, you could display results for the arms, head, and neck locations if you don't wish
to see the full analysis.

You can "@Cdelete@W" an existing analysis by providing the name of the analysis.

The default behavior is to analyze every possible level.  However, this can take considerable
time to complete.  You may optionally request an analysis for every N levels and skip the
analysis for other levels.  For example, "@Gdinv analyze create psi-melee 10@W" will only
perform an analysis every 10 levels.

Examples:
  1) Create a set analysis for the psi-melee priority (see "@Gdinv help priority@W" for details.)
     This generates a lot of output so I am just including a snippet below for levels 150 - 161.
     The "@R<<@W" symbol at the front of each entry indicates an item that is being removed at
     that level while the "@G>>@W" symbol indicates that the item is the new replacement.  If an
     item stays the same from one level to the next, it is not displayed by default.
     "@Gdinv analyze create psi-melee@W"

@Y--------------------------------------------@W Level 150 @Y--------------------------------------------
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W121@w @R<<@W a @RSta@Wre of @RAgo@Wny@w      @Weyes     @G  12@W @G  12@W @G  2@W @G  3@W @G  7@W   0 @G  2@W   0 @G 13@W    0    0    0
@W150@w @G>>@W the @cO@Dcu@cl@Dus@w of the @cK'  @Weyes        0 @G  26@W   0 @G 10@W @G 10@W   0   0   0 @G 10@W    0    0    0
@w
@WLvl Name of Treasure         Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W100@w @R<<@W @RAardwolf@Y Bracers of I @Warms     @G  20@W @G  20@W   0   0   0   0   0   0   0 @G 100@W @G 100@W    0
@W150@w @G>>@W @RAardwolf@Y Bracers of I @Warms     @G  30@W @G  30@W   0   0   0   0   0   0   0 @G 150@W @G 150@W    0
@W100@w @R<<@W @RAardwolf@Y Gloves of De @Whands    @G  20@W @G  20@W   0   0   0   0 @G  6@W   0   0 @G 100@W @G 100@W @G 100
@W150@w @G>>@W @RAardwolf@Y Gloves of De @Whands    @G  30@W @G  30@W   0   0   0   0 @G  6@W   0   0 @G 150@W @G 150@W @G 150
@w
@Y--------------------------------------------@W Level 151 @Y--------------------------------------------
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W131@w @R<<@W (@ySubstance@w of the @gUni @Wback        0 @G  14@W @G 12@W   0 @G  2@W   0   0   0 @G 13@W @G  60@W    0 @R-120
@W151@w @G>>@W a black tunic lined w @Wback     @G   5@W @G  21@W @G 12@W @G  4@W @G  2@W @G  1@W @G  1@W   0   0    0    0    0
@w
@Y--------------------------------------------@W Level 160 @Y--------------------------------------------
@w
@WLvl Name of Weapon           Type     Ave Wgt   HR   DR Dam Type Specials Int Wis Lck Str Dex Con
@W140@w @R<<@W @YDagger of @RAardwolf@w    @Wwielded  @G420@W @G 10@W @G  14@W @G  14@W Light    sharp      0   0   0   0   0   0
@W160@w @G>>@W @YAxe of @RAardwolf@w       @Wwielded  @G480@W @G 20@W @G  16@W @G  16@W Slash    vorpal     0   0   0   0   0   0
@W140@w @R<<@W @YAxe of @RAardwolf@w       @Wsecond   @G420@W @G  1@W @G  14@W @G  14@W Pierce   flaming    0   0   0   0   0   0
@W160@w @G>>@W @YDagger of @RAardwolf@w    @Wsecond   @G480@W @G 10@W @G  16@W @G  16@W Pierce   sharp      0   0   0   0   0   0
@w
@Y--------------------------------------------@W Level 161 @Y--------------------------------------------
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W131@w @R<<@W @Dthe @YEye @Dof @MHorus Earr @Wlear     @G   6@W @G   8@W @G  8@W   0 @G  3@W   0   0   0 @G 12@W    0    0    0
@W161@w @G>>@W @Y(@y%@c*@C=@W- @CR@coar @wof @YV@yictory @Wlear        0 @G  20@W @G  4@W @G  4@W @G  3@W @G  8@W @G  4@W   0 @G 14@W @G  60@W    0 @R-120
@W131@w @R<<@W @Dthe @YEye @Dof @MHorus Earr @Wrear     @G   6@W @G   8@W @G  8@W   0 @G  3@W   0   0 @G  1@W @G 12@W    0    0    0
@W161@w @G>>@W @Y(@y%@c*@C=@W- @CR@coar @wof @YV@yictory @Wrear     @G   2@W @G  14@W @G  4@W @G  4@W @G  6@W @G  8@W @G  4@W   0 @G 14@W @G  60@W    0 @R-120
@W121@w @R<<@W @gSt@Ge@Wa@Gd@gfa@Gs@Wt@Gn@ges@Gs@w         @Wlwrist   @G   4@W @G  13@W   0 @G  4@W @G  3@W @G  3@W   0 @G  4@W @G 12@W @G  50@W    0 @R -90
@W161@w @G>>@W @BTeran's @bDeath @BGrip@w    @Wlwrist   @G   3@W @G  18@W   0 @G  3@W @G  5@W @G 12@W   0   0   0    0    0    0
@W131@w @R<<@W S@wp@Wi@wk@We @wS@Wt@wu@Wd@wd@We@wd @GB@gr@Ga@gc@Ge@gr  @Wrwrist      0 @G  12@W @G  9@W   0 @G  3@W   0 @G  2@W   0 @G 13@W @G  25@W    0 @R -50
@W161@w @G>>@W @YM@yana@ccle@Cs of S@capi@yenc@Ye  @Wrwrist      0 @G  14@W @G 12@W @G  2@W @G  2@W   0   0   0 @G 16@W    0 @G  60@W @R-120
@W

  2) Let's see what the available "optimal" leg items are at each level.  Hmm.  Looks like I'm
     missing some decent L71 legs and I don't have anything between L91 and L181.  That helps
     me identify places where I could potentially get better equipment.  I'm using the "@Cdisplay@W"
     mode here because I'm happy with the sets we created in the previous example and I don't
     want to duplicate that work again by creating the analysis a second time.
     "@Gdinv analyze display psi-melee legs@W"

@Y--------------------------------------------@W Level  11 @Y--------------------------------------------
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W  1@w @G>>@W @C(@W+@C) @WC@Coolin@Wg Z@Cephy@Wr @C(  @Wlegs     @G   5@W @G   2@W   0   0 @G  2@W @G  1@W   0   0   0    0    0    0
@w
@Y--------------------------------------------@W Level  21 @Y--------------------------------------------
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W  1@w @R<<@W @C(@W+@C) @WC@Coolin@Wg Z@Cephy@Wr @C(  @Wlegs     @G   5@W @G   2@W   0   0 @G  2@W @G  1@W   0   0   0    0    0    0
@W 21@w @G>>@W a hero's leggings     @Wlegs     @G   6@W @G   2@W   0 @G  4@W @G  3@W   0 @G  4@W   0   0    0    0    0
@w
@Y--------------------------------------------@W Level  41 @Y--------------------------------------------
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W 21@w @R<<@W a hero's leggings     @Wlegs     @G   6@W @G   2@W   0 @G  4@W @G  3@W   0 @G  4@W   0   0    0    0    0
@W 41@w @G>>@W @G(>@RL@Ya@Rv@Ya S@Rh@Yi@Rn G@Yu@Ra@Yr@Rd@Ys@G<)  @Wlegs        0 @G  10@W   0 @G  4@W @G  4@W @G  4@W   0   0 @G  4@W @G  20@W    0 @R -40
@w
@Y--------------------------------------------@W Level  91 @Y--------------------------------------------
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W 41@w @R<<@W @G(>@RL@Ya@Rv@Ya S@Rh@Yi@Rn G@Yu@Ra@Yr@Rd@Ys@G<)  @Wlegs        0 @G  10@W   0 @G  4@W @G  4@W @G  4@W   0   0 @G  4@W @G  20@W    0 @R -40
@W 91@w @G>>@W @r-=@RAn@rcie@Rnt @WSamurai @RS@rou @Wlegs     @G   7@W @G  12@W @G  1@W @G  2@W @G  1@W @G  2@W @G  2@W @G  1@W @G  9@W    0    0    0
@w
@Y--------------------------------------------@W Level 181 @Y--------------------------------------------
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W 91@w @R<<@W @r-=@RAn@rcie@Rnt @WSamurai @RS@rou @Wlegs     @G   7@W @G  12@W @G  1@W @G  2@W @G  1@W @G  2@W @G  2@W @G  1@W @G  9@W    0    0    0
@W181@w @G>>@W @GT@gou@Ggh @YL@yeath@Yer @WC@wha@Wps@w   @Wlegs     @G   6@W @G  16@W   0 @G  3@W   0 @G 18@W   0   0 @G 18@W    0    0    0
@w
@Y--------------------------------------------@W Level 200 @Y--------------------------------------------
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W181@w @R<<@W @GT@gou@Ggh @YL@yeath@Yer @WC@wha@Wps@w   @Wlegs     @G   6@W @G  16@W   0 @G  3@W   0 @G 18@W   0   0 @G 18@W    0    0    0
@W200@w @G>>@W @R(FAKE) @GXeno's @YKnicker @Glegs    @W @G  23@W @G  20@W   0 @G  3@W @G  5@W   0   0   0 @G 19@W @G 200@W    0    0
@W

  3) You can also specify multiple wearable locations to display.  In this example, we will show
     results for the hands, feet, neck1, and rwrist locations.  I'm not displaying the output here.
     I think the helpfile is big enough already :)
     "@Gdinv analyze display psi-melee hands feet neck1 rwrist@W"

  4) Now that you have created the "psi-melee" analysis, it will show up on your analysis list.
     "@Gdinv analyze list@W"

  5) If you are done with the analysis, you can delete it.  You may wish to do this to save disk
     space or to speed up the speed of creating a backup.
     "@Gdinv analyze delete psi-melee@W"

  6) Create a partial set analysis by only analyzing every 10 levels for the psi-melee priority.
     "@Gdinv analyze create psi-melee 10@W"
]])

end -- inv.cli.analyze.examples


inv.cli.usage = {}
function inv.cli.usage.fn(name, line, wildcards)
  local priorityName = wildcards[1] or ""
  local query        = wildcards[2] or ""
  local endTag       = inv.tags.new(line)

  dbot.debug("inv.cli.usage.fn: priority=\"" .. priorityName .. "\", query=\"" .. query .. "\"")

  local guardFail = inv.cli.requireReadyStateFor("usage")
  if guardFail then return inv.tags.stop(invTagsUsage, endTag, guardFail) end

  if (priorityName == "") then
    inv.cli.usage.usage()
    return inv.tags.stop(invTagsUsage, endTag, DRL_RET_INVALID_PARAM)
  else
    inv.usage.display(priorityName, query, endTag)
  end -- if

end -- inv.cli.usage.fn


function inv.cli.usage.usage()
  dbot.print("@W    " .. pluginNameCmd .. " usage @G<priority name | all | allUsed> <query>@w")
end -- inv.cli.usage.usage


function inv.cli.usage.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.usage.usage()

  dbot.print(
[[@W
It is very useful to see which items are being used and at what levels they are in your
equipment sets.  To use this feature, you must specify a priority (see "@Gdinv help priority@W")
that has a completed analysis available (see "@Gdinv help analyze@W") and a query indicating
which items you wish to examine (see "@Gdinv help search@W").  Any items that match the
specified query will be displayed along with information about where (and if) the item is
used for the given priority.

If an item isn't used with one priority, it may still be used by another priority.  For
example, a high int/wis/luck item may be useful for an "@Cenchanter@W" priority even if that
item isn't used by your normal leveling equipment set.

Also, the usage analysis isn't perfect.  The plugin can't know what your spell bonuses will
be at any given time so it must make some educated guesses.  If you get a superhero spellup
then the optimal equipment for you while that spellup lasts could be different than what
is shown in the usage output.

In short, use the usage report as a best guess but don't assume that the results won't
change depending on your circumstances.

Examples:
  1) See which level 1-100 weapons are used and at which levels they are used for the
     "@Cpsi-melee@W" priority.  Notice the L60 dagger that is used at two level ranges.
     It is used between L60-L79 and again at L90-L99.  It's a maxed dagger (I bought it
     cheap on the market, yay :) and the extra DR and HR would be great between L80-L89
     but I can't use it there because of weight restrictions.  This is helpful for me
     to see that I may want to setweight that dagger.
     "@Gdinv usage psi-melee type weapon maxlevel 100@W"

@G  8@W @wa @yFlame@rthrower@w                  @G(1805970172) @YWeapon@W psi-melee @G11-39
@R  8@W the captain's bastard sword     @G(1852932476) @YWeapon@W psi-melee @RUnused
@G 11@W @YDagger of @RAardwolf@w               @G(808961542) @YWeapon@W psi-melee @G11-19
@G 20@W S@we@Wa@wr@Wi@wn@Wg @wB@Wl@wa@Wz@we                   @G(1743467081) @YWeapon@W psi-melee @G20-25
@G 26@W @bM@Belpomene's @bB@Betrayal@w            @G(1839990561) @YWeapon@W psi-melee @G26-39
@G 40@W @YDagger of @RAardwolf@w              @G(1649835494) @YWeapon@W psi-melee @G40-59
@G 40@W @YDagger of @RAardwolf@w                 @G(2278063) @YWeapon@W psi-melee @G40-70
@G 60@W @YAxe of @RAardwolf@w                  @G(769621598) @YWeapon@W psi-melee @G71-79
@G 60@W @YDagger of @RAardwolf@w               @G(323630037) @YWeapon@W psi-melee @G60-79 90-99
@G 80@W @YAxe of @RAardwolf@w                 @G(1759116162) @YWeapon@W psi-melee @G80-89
@G 80@W @YDagger of @RAardwolf@w              @G(1778400033) @YWeapon@W psi-melee @G80-89
@G 90@W @YDagger of @RAardwolf@w               @G(404748066) @YWeapon@W psi-melee @G90-99
@G100@W @YAxe of @RAardwolf@w                  @G(250640058) @YWeapon@W psi-melee @G100-109
@G100@W @YDagger of @RAardwolf@w              @G(1778448920) @YWeapon@W psi-melee @G100-109@W

  2) Let's look at my neck gear between levels 1 - 100.  Wow, I have a lot of junk that I should
     probably dump.  My "cute widdle ears" aren't endearing enough to keep around if I never use
     them...
     "@Gdinv usage psi-melee wearable neck maxlevel 100@W"

@G  1@W @C(@W+@C) @WB@Citin@Wg W@Cind@Ws @C(@W+@C)@w            @G(1834123713) @YArmor@W psi-melee @G11-40
@R  1@W @C(@W+@C) @WB@Citin@Wg W@Cind@Ws @C(@W+@C)@w            @G(1743021081) @YArmor@W psi-melee @RUnused
@G  1@W @C(@W+@C) @WB@Citin@Wg W@Cind@Ws @C(@W+@C)@w            @G(1834123697) @YArmor@W psi-melee @G11-40
@R  1@W @wc@Wut@we @yw@Yiddl@ye @mka@Mwa@wi@Wi c@wat@M ea@mrs@w     @G(1834121351) @YArmor@W psi-melee @RUnused
@R  1@W @wc@Wut@we @yw@Yiddl@ye @mka@Mwa@wi@Wi c@wat@M ea@mrs@w     @G(1834121344) @YArmor@W psi-melee @RUnused
@R  1@W @wc@Wut@we @yw@Yiddl@ye @mka@Mwa@wi@Wi c@wat@M ea@mrs@w     @G(1834121347) @YArmor@W psi-melee @RUnused
@R  1@W @wc@Wut@we @yw@Yiddl@ye @mka@Mwa@wi@Wi c@wat@M ea@mrs@w     @G(1753181926) @YArmor@W psi-melee @RUnused
@R 41@W (>@cAs@Cura@W's Az@Buri@Wte P@Cea@crl@W<)@w       @G(1744225929) @YArmor@W psi-melee @RUnused
@G 41@W (>@cAs@Cura@W's Az@Buri@Wte P@Cea@crl@W<)@w       @G(1834452605) @YArmor@W psi-melee @G41-70
@G 41@W (>@cAs@Cura@W's Az@Buri@Wte P@Cea@crl@W<)@w       @G(1834452600) @YArmor@W psi-melee @G41-99
@R 41@W (>@cAs@Cura@W's Az@Buri@Wte P@Cea@crl@W<)@w       @G(1757388666) @YArmor@W psi-melee @RUnused
@G 71@W >@M.@m: @RC@Mr@Ye@Ga@Bt@ci@mv@We License @m:@M.@W<@w        @G(1758619847) @YArmor@W psi-melee @G71-90
@R 71@W >@M.@m: @RC@Mr@Ye@Ga@Bt@ci@mv@We License @m:@M.@W<@w        @G(1813070241) @YArmor@W psi-melee @RUnused
@G 91@W @y>@Y}@rPho@Ren@Yix's @RPe@rrch@Y{@y<@w             @G(1584559998) @YArmor@W psi-melee @G91-140
@R 91@W @Dthe @YAmulet @Dof @MAnubis@w            @G(1235973081) @YArmor@W psi-melee @RUnused
@R 91@W @Dthe @YCharm @Dof @MKnowledge@w          @G(1745132926) @YArmor@W psi-melee @RUnused
@R100@W a protective cloak skinned from @G(1695078138) @YArmor@W psi-melee @RUnused
@G100@W a protective cloak skinned from @G(1672257124) @YArmor@W psi-melee @G100-170@W

  3) You can even use the "all" search string to find the usage for all of your items.  I'm
     not copying that output into this helpfile though :)
     "@Gdinv usage psi-melee all@W"
]])

end -- inv.cli.usage.examples


inv.cli.unused = {}
function inv.cli.unused.fn(name, line, wildcards)
  local priorityName = wildcards[1] or ""
  local options      = Trim(wildcards[2] or "")
  local endTag       = inv.tags.new(line)

  dbot.debug("inv.cli.unused.fn: priority=\"" .. priorityName .. "\", options=\"" .. options .. "\"")

  local guardFail = inv.cli.requireReadyStateFor("unused")
  if guardFail then return inv.tags.stop(invTagsUnused, endTag, guardFail) end

  if (priorityName == "") then
    inv.cli.unused.usage()
    return inv.tags.stop(invTagsUnused, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  local nokeep = false
  if (options == "nokeep") then
    nokeep = true
  elseif (options ~= "") then
    dbot.info("Unknown unused option: \"" .. options .. "\"")
    inv.cli.unused.usage()
    return inv.tags.stop(invTagsUnused, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  inv.unused.display(priorityName, nokeep, endTag)
end -- inv.cli.unused.fn


function inv.cli.unused.usage()
  dbot.print("@W    " .. pluginNameCmd .. " unused @G<priority name | all> @Y[nokeep]@w")
end -- inv.cli.unused.usage


function inv.cli.unused.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.unused.usage()

  dbot.print(
[[@W
Lists owned wearable items that do not appear in any analyzed equipment set for the
specified priority.  This is useful for identifying gear you can sell, donate, or junk.

An item is "part of a priority" if it appears in that priority's analyzed sets at any
level (see "@Gdinv help analyze@W").  All other owned wearables are reported here.

The report excludes items that are not equipment candidates:
  - Consumables (potions, pills, food, scrolls, wands, staves, drinks, fountains)
  - Non-gear (portals, keys, beacons, giftcards, containers, furniture, trash,
    boats, corpses, campfires, forges, runestones, raw materials)
  - Items referenced by any snapshot (see "@Gdinv help snapshot@W")
  - Items located anywhere other than inventory, vault, keyring, worn, or auction

Specify "@Gall@W" to consider every priority that has analyze data.  Priorities without
analyze data are skipped (the list is reported so you can see which).  Items shown for
"@Gall@W" are items that aren't in any analyzed priority's sets -- strong candidates for
disposal.

Specifying a single priority name strictly requires that priority to have analyze data;
otherwise the command refuses and tells you to run "@Gdinv analyze create <priority>@W"
first.  This avoids misleading results from a missing analysis.

The optional "@Ynokeep@W" argument excludes items flagged KEEP.  By default, KEEP-flagged
items are included so characters that flag every item as KEEP still see useful output.

Examples:
  1) List items not part of the "@Cpsi-melee@W" priority's analyzed sets.
     "@Gdinv unused psi-melee@W"

  2) Same, but exclude items flagged KEEP.
     "@Gdinv unused psi-melee nokeep@W"

  3) List items not part of any analyzed priority -- strong sell/donate candidates.
     "@Gdinv unused all@W"

Output columns: required level, color-coded object ID and name, item type, object
location (inventory, vault, keyring, worn, auction).
]])

end -- inv.cli.unused.examples


inv.cli.compare = {}
function inv.cli.compare.fn(name, line, wildcards)
  local priorityName = wildcards[1] or ""
  local relativeName = wildcards[2] or ""
  local levelSkip    = tonumber(wildcards[3] or "1") or 1
  local endTag       = inv.tags.new(line, "Compare results", nil, inv.tags.cleanup.timed)

  dbot.debug("inv.cli.compare.fn: priority=\"" .. priorityName .. "\", relativeName=\"" ..
             relativeName .. "\"")

  local guardFail = inv.cli.requireActiveStateFor("compare")
  if guardFail then return inv.tags.stop(invTagsCompare, endTag, guardFail) end

  if (levelSkip < 1) then
    levelSkip = 1
  elseif (levelSkip > 200) then
    levelSkip = 200
  end -- if

  if (priorityName == "") or (relativeName == "") then
    inv.cli.compare.usage()
    return inv.tags.stop(invTagsCompare, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  inv.set.compare(priorityName, relativeName, levelSkip, endTag)
end -- inv.cli.compare.fn


function inv.cli.compare.usage()
  dbot.print("@W    " .. pluginNameCmd .. " compare @G<priority name> <relative name> @Y<skip #>@w")
end -- inv.cli.compare.usage


function inv.cli.compare.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.compare.usage()

  dbot.print(
[[@W
The plugin gives you the ability to see the impact that a particular item has on all
equipment sets for all levels.  It is very difficult to determine how valuable an item
is until you evaluate what your equipment sets would look like if it were not available.
It isn't simply a matter of finding a replacement part and looking at the difference
betwen the two items.  Removing one item can have a cascading effect on other wearable
locations.  In some cases, the overall impact may be very small while in other cases it
could be significant.

The "@Ccompare@W" mode requires you to have the item you wish to evaluate in your main
inventory.  It cannot be worn or be in a container.  You must also have a completed
analysis available (see "@Gdinv help analyze@W") for the priority (see "@Gdinv help priority@W")
that is specified.

Once these conditions are met, the plugin will temporarily remove the item from your
inventory table and re-run a full equipment analysis for all levels potentially impacted
by the item.  Once the analysis is complete, it will add the item back to your inventory
and display the impact of the item at each level.

By default, the "@Ccompare@W" mode analyzes every level.  However, this can take considerable
time.  A user may wish a faster comparison that only checks results every N levels.  For
example, checking every 10 levels might look like "@Gdinv compare psi-melee sword 10@W".

Example:
  1) I removed my body item (A Pure and True Heart) and performed a comparison to see how
     valuable that item is.  Having the item increaes my DR, int, and luck but decreases
     my wis, str, dex, and con.  According to the priorities I specified, the additions
     outweigh the negatives and the plugin chose to use this item in my equipment sets for
     levels 200 - 211 (level 211 includes 10 levels for my T1 tier bonus.)  This is a
     helpful and concrete way to evaulate priorities.
     "@Gdinv compare psi-melee heart@W"

@WAnalyzing optimal "@Cpsi-melee@W" equipment sets with and without "-@m=@W*@m)@WA @MP@mure @Ma@mnd @MT@mrue @WHeart@m(@W*@m=@W-@w"
@w
@WEquipment analysis of "@Cpsi-melee@W": @G  0%
@WEquipment analysis of "@Cpsi-melee@W": @G 90%
@WEquipment analysis of "@Cpsi-melee@W": @G100%
@w
@WPriority "@Cpsi-melee@W" advantages with "-@m=@W*@m)@WA @MP@mure @Ma@mnd @MT@mrue @WHeart@m(@W*@m=@W-":
@w
@W           Ave Sec  HR  DR Int Wis Lck Str Dex Con Res HitP Mana Move Effects
@WLevel 200:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 201:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 202:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 203:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 204:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 205:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 206:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 207:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 208:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 209:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 210:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0
@WLevel 211:   0   0   0 @G  7@W @G  8@W @R -2@W @G  2@W @R -7@W @R -2@W @R -5@W   0    0    0    0 @W
]])

end -- inv.cli.compare.examples


inv.cli.covet = {}
function inv.cli.covet.fn(name, line, wildcards)
  local priorityName = wildcards[1] or ""
  local auctionNum   = tonumber(wildcards[2] or "")
  local levelSkip    = tonumber(wildcards[3] or "1") or 1
  local endTag       = inv.tags.new(line, "Covet results", nil, inv.tags.cleanup.timed)

  local guardFail = inv.cli.requireActiveStateFor("covet")
  if guardFail then return inv.tags.stop(invTagsCovet, endTag, guardFail) end

  if (auctionNum == nil) then
    dbot.warn("inv.cli.covet: auction # is not a number")
    inv.cli.covet.usage()
    return inv.tags.stop(invTagsCovet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (priorityName == "") then
    dbot.warn("inv.cli.covet: priorityName is empty")
    inv.cli.covet.usage()
    return inv.tags.stop(invTagsCovet, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  dbot.debug("inv.cli.covet.fn: priority=\"" .. priorityName .. "\", auctionNum=" .. auctionNum)

  if (levelSkip < 1) then
    levelSkip = 1
  elseif (levelSkip > 200) then
    levelSkip = 200
  end -- if

  inv.set.covet(priorityName, auctionNum, levelSkip, endTag)
end -- inv.cli.covet.fn


function inv.cli.covet.usage()
  dbot.print("@W    " .. pluginNameCmd .. " covet @G<priority name> <auction #> @Y<skip #>@w")
end -- inv.cli.covet.usage


function inv.cli.covet.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.covet.usage()

  dbot.print(
[[@W
The plugin's "@Ccovet@W" mode helps you monitor short-term and long-term auctions to help
you find items that can improve stats over your existing equipment.

Pick a priority (see "@Gdinv help priority@W") that has a completed analysis available
(see "@Gdinv help analyze@W"), find a short-term or long-term auction number and you're
good to go.  The plugin will scrape the auction for details about the item, temporarily
add it to your inventory table, re-run a full analysis, and then discard the item from
your inventory table.  By comparing your equipment sets both with and without the item you
can determine the advantages/disadvantages of using that item.

By default, the "@Ccovet@W" mode analyzes every level.  However, this can take considerable
time.  A user may wish a faster comparison that only checks results every N levels.  For
example, checking every 10 levels might look like "@Gdinv covet psi-melee 12345 10@W".

Example:
  1) Evaluate a body item at long-term market #80561.  In this case, it wasn't better than
     my existing equipment, but that is still handy to know!  If it would have been better
     for at least one level, the improvements would have been displayed.  See the helpfile
     at "@Gdinv help compare@W" for examples showing how the output would have looked.
     "@Gdinv covet psi-melee 80561@W"

@WAnalyzing optimal "@Cpsi-melee@W" equipment sets with and without @Gauction 80561
@w
@WLvl Name of Armor            Type       HR   DR Int Wis Lck Str Dex Con Res HitP Mana Move
@W200@w Auction #80561           @Gbody    @W @G  10@W @G  26@W   0 @G  3@W @G  3@W @G 15@W @G  5@W @G  5@W @G 19@W    0 @G 100@W @R-200
@w
@WPriority "@Cpsi-melee@W" advantages with @Gauction #80561@w:
@w
@WNo set with item "Synthetic Power" is optimal between between levels 11 and 211@W
]])

end -- inv.cli.covet.examples


inv.cli.notify = {}
function inv.cli.notify.fn(name, line, wildcards)
  local level  = wildcards[1] or ""
  local endTag = inv.tags.new(line)

  local guardFail = inv.cli.requireReadyStateFor("notify")
  if guardFail then return inv.tags.stop(invTagsNotify, endTag, guardFail) end

  if (level == "none") or (level == "light") or (level == "standard") or (level == "all") then
    dbot.notify.setLevel(level, endTag, true)
  else
    inv.cli.notify.usage()
    return inv.tags.stop(invTagsNotify, endTag, DRL_RET_INVALID_PARAM)
  end -- if
end -- inv.cli.notify.fn


function inv.cli.notify.usage()
  dbot.print("@W    " .. pluginNameCmd .. " notify @G[none | light | standard | all]@w")
end -- inv.cli.notify.usage()


function inv.cli.notify.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.notify.usage()

  dbot.print(
[[@W
The notification system divides optional messages into three classes based on the message's
priority.  The "all" notification mode displays all three optional classes and is the most
verbose mode.  The "standard" notification mode displays the two highest-priority optional
message classes.  The "light" notification mode displays only the most critical optional
messages.  Take a wild guess what the "none" notification mode displays...Warnings and errors
are never optional and the user cannot disable them.

The notification system suppresses all messages -- even warnings and errors -- if the user is
in note-writing mode.  We don't want notifications to appear on a user's note.
]])

  dbot.print("@WThe default notification mode is \"@C" .. notifyLevelDefault .. "@W\"\n")


  -- Enable all message levels so that we can demonstrate them here
  local origMsgLevel = dbot.notify.getLevel()
  dbot.notify.setLevel("all", nil, false)

  dbot.debug("This is a debug message that you probably don't care about.")
  dbot.note("This is a note that might be interesting in some cases.")
  dbot.info("This is information the user probably wants to know.")
  dbot.warn("This is what a warning looks like.")
  dbot.error("This is what an error looks like.")

  dbot.notify.setLevel(origMsgLevel, nil, false)

dbot.print(
[[@W
Examples:
  1) Display all optional (debug, note, and info) messages
     "@Gdinv notify all@W"

  2) Display everything except low-priority debug messages
     "@Gdinv notify standard@W"

  3) Display only the most critical messages
     "@Gdinv notify light@W"

  4) Disable all optional messages and display only warnings and errors
     "@Gdinv notify none@W"
]])

end -- inv.cli.notify.examples


inv.cli.regen = {}
function inv.cli.regen.fn(name, line, wildcards)
  local regenMode = wildcards[1] or ""

  if (regenMode == "on") then
    dbot.info("Regen mode is @GENABLED@W")
    inv.config.table.isRegenEnabled = true
  elseif (regenMode == "off") then
    dbot.info("Regen mode is @RDISABLED@W")
    inv.config.table.isRegenEnabled = false
  else
    dbot.warn("inv.cli.regen.fn: Invalid regen mode \"" .. (regenMode or "nil") .. "\"")
  end -- if

  inv.regen.aliasEnable(inv.config.table.isRegenEnabled)

  return inv.config.save()

end -- inv.cli.regen.fn


function inv.cli.regen.fn2(name, line, wildcards)
  local sleepMode = wildcards[1] or ""
  local sleepLoc  = wildcards[2] or ""

  dbot.debug("sleepLoc is \"" .. sleepLoc .. "\"")
  return inv.regen.onSleep(sleepLoc)
end -- inv.cli.regen.fn2


function inv.cli.regen.usage()
  dbot.print("@W    " .. pluginNameCmd .. " regen @G[on | off]@w")
end -- inv.cli.regen.usage


function inv.cli.regen.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.regen.usage()

  dbot.print(
[[@W
The regeneration effect while sleeping is very helpful for your recovery.  This mode checks if
you currently are wearing a regeneration ring and if you have one available to you.  If you have
one available and you are not yet wearing anything providing the regeneration effect, the @Cregen@W
mode will auto-wear your regeneration ring for you when you sleep.  When you wake, dinv will
automatically swap back your previous ring and store the regeneration ring.

If you do not have any items providing regeneration, this mode will not do anything.  Similarly,
if you have multiple regeneration rings, this mode will only attempt to wear one of them when you
sleep.  Your regeneration ring(s) can be in your main inventory or in any open container.  Dinv
will find them and put them back when it is done.

@YNote@W: This mode will not detect when you sleep if you use an alias to sleep.  In other words, if
you alias sleep to "goNightNight" and then type "goNightNight" you won't auto-wear your regen ring.

@YNote@W: Some custom exits (e.g., fantasy fields) use the "sleep" command to enter a room.  This
will conflict with the regen mode because that custom exit will not actually put you to sleep.
As a result, you will not re-wear your original finger equipment until you sleep and wake.  It
is recommended that you use " sleep" (add a space before sleep) for custom exits.  The regen
"sleep" alias will not trigger if one or more spaces is before the sleep command.

Example:
  1) Enable regen mode
     "@Gdinv regen on@W"

  2) Disable regen mode
     "@Gdinv regen off@W"
]])

end -- inv.cli.regen.examples


inv.cli.forget = {}
function inv.cli.forget.fn(name, line, wildcards)
  local query  = wildcards[1] or ""
  local endTag = inv.tags.new(line)

  local guardFail = inv.cli.requireReadyStateFor("forget")
  if guardFail then return inv.tags.stop(invTagsForget, endTag, guardFail) end

  inv.items.forget(query, endTag)
end -- inv.cli.forget.fn


function inv.cli.forget.usage()
  dbot.print("@W    " .. pluginNameCmd .. " forget @G<query>@w")
end -- inv.cli.forget.usage


function inv.cli.forget.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.forget.usage()

  dbot.print(
[[@W
You may occasionally want to "forget" everything you know about an item and
re-identify it for your inventory table.  As noted in the plugin release notes,
there are a few situations where this may occur.

You can enchant an item yourself and the plugin will notice and update stats for
the newly enchanted item on your next item refresh.  However, if item caching is
enabled, you could hit an issue if you give an item to an enchanter and receive
it back after it gets a boost in stats.  By default, the plugin will pull
information about the item from the cache -- but the cache now has old information.
In this case, you will need to "forget" the item and then re-run an inventory
refresh to pick up the change.

Most aard operations that modify an item's stats are detected and automatically
trigger a re-identification on your next item refresh.  For example, enchantment
spells, sharpening, reinforcing, tpenchanting, and wset all are handled transparently.
The one known exception is the setweight command which is not currently handled by
aard's invitem system.  Until this is changed (or until we include a trigger watching
for setweight) you will need to use the "@Gdinv forget <query>@W" option on an item
that changes weight in order to "forget" the old stats and then pick up the correct
weight (and other stats) on the next inventory refresh.

See the "@Gdinv help search@W" helpfile for examples and more information about
creating search queries for items that you want to forget.

Examples:
  1) Forget and re-identify a ring you just received back from an enchanter using
     a "relative name" to indicate which item in your main inventory should be
     forgotten.
     "@Gdinv forget rname 2.ring@W"
     "@Gdinv refresh all@W"

  2) Forget about all of your aard weapons (maybe you just changed their weights)
     "@Gdinv forget type weapon keyword aardwolf@W"
]])

end -- inv.cli.forget.examples


inv.cli.ignore = {}
function inv.cli.ignore.fn(name, line, wildcards)
  local mode      = wildcards[1] or ""
  local container = wildcards[2] or ""
  local endTag    = inv.tags.new(line)

  local guardFail = inv.cli.requireReadyStateFor("ignore")
  if guardFail then return inv.tags.stop(invTagsIgnore, endTag, guardFail) end

  if (string.lower(mode) == "list") then
    return inv.tags.stop(invTagsIgnore, endTag, inv.items.listIgnored())
  else
    inv.items.ignore(mode, container, endTag)
  end -- if
end -- inv.cli.ignore.fn


function inv.cli.ignore.usage()
  dbot.print("@W    " .. pluginNameCmd .. " ignore @G[on | off | list] <keyring | container relative name>@w")
end -- inv.cli.ignore.usage


function inv.cli.ignore.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.ignore.usage()

  dbot.print(
[[@W
The @Cignore@W mode allows you to specify one or more containers that the plugin should ignore.
Any ignored container and any items in an ignored container are not included when the plugin is
searching, getting, putting, storing, organizing, and creating or wearing equipment sets.

You may also use "keyring" as a container name to indicate ignoring everything on your keyring.

The @Clist@W option reports which (if any) locations are currently ignored.

Examples:
  1) Ignore "3.bag" in your main inventory
     @Gdinv ignore on 3.bag@W

  2) Stop ignoring "3.bag"
     @Gdinv ignore off 3.bag@W

  3) Ignore everything on your keyring
     @Gdinv ignore on keyring@W

  4) Stop ignoring your keyring contents
     @Gdinv ignore off keyring@W

  5) Report which locations (keyring or containers) are currently ignored
     @Gdinv ignore list@W
]])

end -- inv.cli.ignore.examples


inv.cli.reset = {}
function inv.cli.reset.fn(name, line, wildcards)
  local command = wildcards[1] or ""
  local modules = wildcards[2] or ""
  local endTag  = inv.tags.new(line)

  dbot.debug("reset CLI: command = \"" .. command .. "\", modules = \"" .. modules .. "\"")

  if (command == "list") then
    dbot.print("@WResettable \"@G" .. pluginNameAbbr .. "@W\" modules: \"@C" .. inv.modules .. "@W\"")
  elseif (command == "confirm") then
    inv.reset(modules, endTag)
  else
    inv.cli.reset.usage()
    inv.tags.stop(invTagsReset, endTag, DRL_RET_INVALID_PARAM)
  end -- if
end -- inv.cli.reset.fn


function inv.cli.reset.usage()
  dbot.print("@W    " .. pluginNameCmd .. " reset @G[list | confirm] <module names | all>@w")
end -- inv.cli.reset.usage


function inv.cli.reset.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.reset.usage()
  dbot.print(
[[@W
In a perfect world, there would never be a reason to use the "@Creset@W" mode.
However, it is useful to have the ability to reset particular components of the
plugin even if (hopefully) they are never required.  Please look at "@Gdinv help
backup@W" and create a backup before you use this.  I *really* don't want to get
notes complaining about losing something because you reset it :).

The following plugin components currently have the ability to be individually
reset back to default values:
  @Cconfig@W:    This holds version info and some of your preferences.  You will
             need to rebuild your inventory table if you reset this.
  @Citems@W:     This is your inventory table.  You'll need to rebuild it if you
             reset this.
  @Ccache@W:     This clears your "recent item cache", "frequently used item cache",
             and "customization item cache".
  @Csnapshot@W:  This table stores all custom equipment set snapshots that you have
             created.
  @Cpriority@W:  This wipes out all custom stat priorities and implements the
             default values.
  @Cset@W:       This is where all of your equipment set data is stored when you
             run a "@Gdinv analyze create [...]@W" operation.  If your backups
             are getting a little big, you may want to wipe the equipment sets
             and regenerate just the ones you currently care about.
  @CstatBonus@W: This table maintains a weighted average of your spell bonuses at
             each level.
  @Cconsume@W:   This table keeps track of which consumable items (typically pills
             and potions) you use and where you can buy the items.
  @Ctags@W:      This table tracks which plugin tags are enabled and if the tag
             framework is enabled.

Examples:
  1) See which modules are currently resetable with this plugin.  Hopefully the list
     matches the components shown above in this helpfile.  If that's not the case,
     please send a note to Durel and let me know so that I can update the helpfile.
     "@Gdinv reset list@W"

  2) Reset the "@Cset@W" component because it is filled with data for lots of junk
     priorities and you want smaller backups.
     "@Gdinv reset confirm set@W"

  3) Reset the "@Cconfig@W" table and inventory table "@Citems@W".
     "@Gdinv reset confirm config items@W"

  4) Reset everything.  This is equivalent to whacking the entire plugin and starting
     from scratch.
     "@Gdinv reset confirm all@W"

]])

end -- inv.cli.reset.examples


inv.cli.backup = {}
function inv.cli.backup.fn(name, line, wildcards)
  local command    = wildcards[1] or ""
  local backupName = wildcards[2] or ""
  local retval     = DRL_RET_SUCCESS
  local endTag     = inv.tags.new(line)

  dbot.debug("backup CLI: command = \"" .. command .. "\", backupName = \"" .. backupName .. "\"")

  if (not inv.init.initializedActive) then
    dbot.info("Skipping backup request: plugin is not yet initialized (are you AFK or sleeping?)")
    retval = inv.tags.stop(invTagsBackup, endTag, DRL_RET_UNINITIALIZED)

  elseif (command == "list") then
    retval = dbot.backup.list(endTag)

  elseif (not dbot.gmcp.stateIsActive()) then
    dbot.info("Skipping backup request: character is not in the active state")
    retval = inv.tags.stop(invTagsBackup, endTag, DRL_RET_NOT_ACTIVE)

  elseif (command == "create") and (backupName ~= "") then
    retval = dbot.backup.create(backupName, endTag)

  elseif (command == "delete") and (backupName ~= "") then
    retval = dbot.backup.delete(backupName, endTag, false)

  elseif (command == "restore") and (backupName ~= "") then
    retval = dbot.backup.restore(backupName, endTag)

  else
    inv.cli.backup.usage()
    retval = inv.tags.stop(invTagsBackup, endTag, DRL_RET_INVALID_PARAM)

  end -- if

  if (retval ~= DRL_RET_SUCCESS) then
    dbot.debug("inv.cli.backup.fn: Unable to perform backup request \"@Y" .. command .. " " .. backupName ..
               "@W\": " .. dbot.retval.getString(retval))
  end -- if
end -- inv.cli.backup.fn


function inv.cli.backup.usage()
  dbot.print("@W    " .. pluginNameCmd ..
             " backup @G[list | create | delete | restore] <backup name>@w")
end -- inv.cli.backup.usage


function inv.cli.backup.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.backup.usage()
  dbot.print(
[[@W
dinv uses SQLite for storage, which provides crash-safe, atomic writes.  Under
normal operation, backups should not be necessary.  However, the backup system
is available as a safety net for peace of mind.

A backup is automatically created before "@Gdinv build confirm@W" if you have
existing inventory data.  You can also create manual backups at any time.

Backups are copies of the SQLite database file, stored in the plugin's backup
directory.  You can list existing backups (sorted by creation date), create new
backups, delete a backup, or restore from an existing backup.

Examples:
  1) Create a new manual backup named "before-enchanting".
     "@Gdinv backup create before-enchanting@W"

  2) List all current backups.
     "@Gdinv backup list@W"

@WDINV@W Detected 2 backups
@w  @W(@c04/03/26 10:15:30@W) @Gbefore-enchanting
@w  @W(@c04/03/26 09:00:12@W) @Gpre-build@W

  3) Delete the "before-enchanting" backup.
     "@Gdinv backup delete before-enchanting@W"

  4) Restore from the "pre-build" backup.  This will replace your current
     inventory database and reload the plugin.
     "@Gdinv backup restore pre-build@W"
]])

end -- inv.cli.backup.examples


inv.cli.cache = {}
function inv.cli.cache.fn(name, line, wildcards)
  local cacheCommand = wildcards[1] or ""
  local cacheType = wildcards[2] or ""
  local cacheSize = -1
  local retval = DRL_RET_SUCCESS
  local endTag = inv.tags.new(line)

  if (wildcards[3] ~= nil) and (wildcards[3] ~= "") then
    cacheSize = tonumber(wildcards[3]) or 0
  end -- if

  dbot.debug("command=\"" .. cacheCommand .. "\", type=\"" .. cacheType .. "\", size=" .. cacheSize)

  local guardFail = inv.cli.requireReadyStateFor("cache")
  if guardFail then return inv.tags.stop(invTagsCache, endTag, guardFail) end

  if (cacheCommand == "reset") then
    if (cacheType == "recent") or (cacheType == "all") then
      retval = inv.cache.resetCache(inv.cache.recent.name)
    end -- if
    if (cacheType == "frequent") or (cacheType == "all") then
      retval = inv.cache.resetCache(inv.cache.frequent.name)
    end -- if
    if (cacheType == "custom") or (cacheType == "all") then
      retval = inv.cache.resetCache(inv.cache.custom.name)
    end -- if

  elseif (cacheCommand == "display") then
    if (cacheType == "recent") or (cacheType == "all") then
      retval = inv.cache.dump(inv.cache.recent.table)
    end -- if
    if (cacheType == "frequent") or (cacheType == "all") then
      retval = inv.cache.dump(inv.cache.frequent.table)
    end -- if
    if (cacheType == "custom") or (cacheType == "all") then
      retval = inv.cache.dump(inv.cache.custom.table)
    end -- if

  elseif (cacheCommand == "size") then
    if (cacheType == "recent") or (cacheType == "all") then
      if (cacheSize < 0) then
        dbot.print("@WRecent item cache:   " .. dbot.table.getNumEntries(inv.cache.recent.table.entries) ..
                   " / " .. (inv.cache.getSize(inv.cache.recent.table) or 0) .. " entries are in use@w")
      else
        retval = inv.cache.setSize(inv.cache.recent.table, cacheSize)
      end -- if
    end -- if
    if (cacheType == "frequent") or (cacheType == "all") then
      if (cacheSize < 0) then
        dbot.print("@WFrequent item cache: " .. dbot.table.getNumEntries(inv.cache.frequent.table.entries) ..
                   " / " .. (inv.cache.getSize(inv.cache.frequent.table) or 0) .. " entries are in use@w")
      else
        retval = inv.cache.setSize(inv.cache.frequent.table, cacheSize)
      end -- if
    end -- if
    if (cacheType == "custom") or (cacheType == "all") then
      if (cacheSize < 0) then
        dbot.print("@WCustom item cache: " .. dbot.table.getNumEntries(inv.cache.custom.table.entries) ..
                   " / " .. (inv.cache.getSize(inv.cache.custom.table) or 0) .. " entries are in use@w")
      else
        retval = inv.cache.setSize(inv.cache.custom.table, cacheSize)
      end -- if
    end -- if

  else
    dbot.warn("inv.cli.cache.fn: Invalid cache command \"" .. cacheCommand .. "\" detected")
    retval = DRL_RET_INVALID_PARAM
  end -- if

  if (retval == DRL_RET_SUCCESS) then
    dbot.info("Cache request completed successfully")
  end -- if

  inv.tags.stop(invTagsCache, endTag, retval)

end -- inv.cli.cache.fn


function inv.cli.cache.usage()
  dbot.print("@W    " .. pluginNameCmd ..
                " cache @G[reset | size] [recent | frequent | custom | all] @Y<# entries>@w")
end -- inv.cli.cache.usage


function inv.cli.cache.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.cache.usage()
  dbot.print(
[[@W
This plugin implements three types of item caches.  The first type is the "@Crecent item@W"
cache.  If an identified item leaves your inventory (e.g., you dropped it or you put
it into your vault) then information about that item is moved to the recent cache.
If you add that item back to your inventory at some point in the future then you won't
need to re-identify the item.  The plugin will pull the necessary info directly from the
recent cache.  This is very convenient and speeds up accessing your vault or using a bag
filled with keys.  By default, the recent cache keeps entries for the 1000 most-recently
used items that left your inventory but you can adjust the cache size as shown below.

The second type of cache is the "@Cfrequently used@W" item cache.  The recent cache stores
information for a specific instance of an item.  In contrast, the frequent cache keeps
generic information for a fungible item (wow, I just used "fungible" in an appropriate
context -- cross that off my bucket list!).  For example, if you have one duff beer, it
will be identical to the other 99 duff beers you just bought so it would be silly to
individually identify all 100 of those beers.  Instead, the plugin will identify your
first duff beer and info on any subsequent duff beers will come from the frequent cache
and avoid re-identification.  By default, the plugin will use the frequent cache for
all potions, pills, and consumable items.  The frequent cache stores information on up
to 100 different items at a time.

The third type of cache is the "@Ccustomization cache@W".  Most details about an item
can be regenerated by re-identifying the item.  However, customizations such as adding
a keyword or adding an organization query to an item could be lost if an item is removed
from your inventory and that item is no longer in your recent cache when you add it back
to your inventory.  The custom cache is a long-lived repository for item customizations
that makes it possible to recover details such as custom keywords or organization queries.
This is especially handy if you die and all of your items are no longer in your inventory.

Examples:
  1) Reset just the recent cache
     "@Gdinv cache reset recent@W"

  2) Reset the recent, frequent, and custom caches
     "@Gdinv cache reset all@W"

  3) Set the number of entries in the frequent cache to 200
     "@Gdinv cache size frequent 200
]])

end -- inv.cli.cache.examples


inv.cli.tags = {}
function inv.cli.tags.fn(name, line, wildcards)
  local retval = DRL_RET_SUCCESS
  local tagNames = wildcards[1] or ""
  local enabled  = wildcards[2] or ""

  dbot.debug("tagNames=\"" .. tagNames .. "\", enabled=\"" .. enabled .. "\"")

  if (not inv.init.initializedActive) then
    dbot.info("Skipping tags request: plugin is not yet initialized (are you AFK or sleeping?)")
    return DRL_RET_UNINITIALIZED
  end -- if

  if (tagNames == "all") then
    tagNames = inv.tags.modules
  end -- if

  if (tagNames == "") then
    if (enabled == drlInvTagOn) then
      retval = inv.tags.enable()
    elseif (enabled == drlInvTagOff) then
      retval = inv.tags.disable()
    elseif (enabled == "") then
      retval = inv.tags.display()
    else
      dbot.warn("inv.cli.tags.fn: Invalid tag value")
      retval = DRL_RET_INVALID_PARAM
    end -- if
  else
    retval = inv.tags.set(tagNames, enabled)
  end -- if

  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.cli.tags.fn: Tags command failed: " .. dbot.retval.getString(retval))
  end -- if

  return retval

end -- inv.cli.tags.fn


function inv.cli.tags.usage()
  dbot.print("@W    " .. pluginNameCmd .. " tags @Y<names | all>@G [on | off]")
end -- inv.cli.tags.usage


function inv.cli.tags.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.tags.usage()
  dbot.print(
[[@W
This plugin supports optional end tags for all operations.  An end tag has the
form "@G{/the command line:execution time in seconds:return value:return value string}@W".
This gives users an easy way to use the plugin in other scripts because those scripts can
trigger on the end tag to know an operation is done and what result the operation had.

For example, if you type "@Gdinv refresh@W", you could trigger on an end tag that has
an output like "@G{/dinv refresh:0:0:success}@W" to know when the refresh completed.  Of
course, you would want to double check the return value in the end tag to ensure
that everything happened the way you want.

The plugin tags subsystem mirrors the syntax for the aardwolf tags subsystem.  Using
"@Gdinv tags@W" by itself will display a list of all supported tags.  You can toggle
one or more individual tags on or off by providing the tag names as follows:
"@Gdinv tags tagName1 tagName2 [on | off]@W".  You can also enable or disable the
entire tag subsystem at once by using "@Gdinv tags [on | off]@W".

If the plugin tags are enabled, they will echo an end tag at the conclusion of an operation.
However, if the user goes into a state (e.g., AFK) that doesn't allow echoing then the plugin
cannot report the end tag.  In this scenario, the plugin will notify the user about the end
tag via a warning notification instead of an echo.  Triggers cannot catch notifications
though so any code relying on end tags should either detect when you go AFK or cleanly time
out after a reasonable amount of time.

Examples:
  1) Display all supported tags
     "@Gdinv tags@W"

  2) Temporarily disable the entire tags subsystem
     "@Gdinv tags off@W"

  3) Turn on tags for the "@Crefresh@W", "@Corganize@W", and "@Cset@W" components
     "@Gdinv tags refresh organize set on@W"

  4) Turn all tags off (but leave the tags subsystem enabled)
     "@Gdinv tags all off@W"
]])

end -- inv.cli.tags.examples


inv.cli.reload = {}
function inv.cli.reload.fn(name, line, wildcards)
  dbot.info("Reloading plugin")

  return dbot.reload()
end -- inv.cli.reload.fn


function inv.cli.reload.usage()
  dbot.print("@W    " .. pluginNameCmd .. " reload")
end -- inv.cli.reload.usage


function inv.cli.reload.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.reload.usage()
  dbot.print(
[[@W
This will unload and then load the plugin.  You should not need to do this but
it never hurts to have the ability if something goes wrong.  This is equivalent
to opening the plugin menu and reinstalling the plugin.
]])

end -- inv.cli.reload.examples


inv.cli.portal = {}
function inv.cli.portal.fn(name, line, wildcards)
  local command = wildcards[1] or ""
  local portalQuery = wildcards[2] or ""

  local guardFail = inv.cli.requireReadyStateFor("portal")
  if guardFail then return guardFail end

  dbot.debug("CLI: " .. pluginNameCmd .. " portal " .. command .. " " .. portalQuery)
  inv.portal.use(portalQuery)

end -- inv.cli.portal.fn


function inv.cli.portal.usage()
  dbot.print("@W    " .. pluginNameCmd .. " portal @G[use] <query>@w")
end -- inv.cli.portal.usage


function inv.cli.portal.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.portal.usage()

  dbot.print(
[[@W
A common situation involves holding a portal and entering it.  This is complicated
by the fact that you might be holding something else originally and you would need
to remember what you held to put it back when you are done with the portal.  This
is further complicated by the portal wish which gives an additional wearable location
that might hold the portal.

Fortunately, we have the plugin to handle all of this for us :)  The plugin checks
if you have a portal wish and uses the correct location automagically.  It also
remembers what was at the location used by the portal so that we can put everything
back when we are done.

The plugin's portal component currently supports only a single mode: "@Cuse@W".  We
may add additional modes in the future.  In the meantime, you can use the following
syntax to automatically get a portal, hold it, enter it, restore anything at the
portal's location, and then put the portal back from whence it came:
"@Gdinv portal use [query]@W".

If more than one portal matches the given query, the first portal found will be
used.  As a result, you almost certainly will want to uniquely identify which portal
you wish to use.  The easiest way to do this is to use the portal's unique ID.  You
can find this ID by searching with the "objid" query mode.  See the
"@Gdinv help search@W" helpfile for details.  As an example, you could see the IDs
of all of your portals by typing "@Gdinv search objid type portal@W".

The plugin's portal mode is particularly convenient when used in conjuction with the
mapper's portal mode.

Examples:
  1) Use the portal with a unique ID of 123456789
     "@Gdinv portal use id 123456789@W"

  2) It is so common to use a portal ID, if the query consists only of a number, it
     is assumed to be a portal's unique ID
     "@Gdinv portal use 123456789@W"

  3) Tell the mapper plugin to use a particular portal automatically from the room
     targeted by portal 123456789
     "@Gmapper portal dinv portal use 123456789@W"

  4) Use a portal that leads to Qong (if more than one portal leads to Qong, the user
     is warned and the first portal found will be used)
     "@Gdinv portal use leadsTo qong@W"

  5) Use a portal that has the keyword blahblahblah
     "@Gdinv portal use key blahblahblah@W"
]])

end -- inv.cli.portal.examples


inv.cli.pass = {}
function inv.cli.pass.fn(name, line, wildcards)
  local passNameOrId = wildcards[1] or ""
  local useTimeSec = tonumber(wildcards[2] or "")

  local guardFail = inv.cli.requireReadyStateFor("pass")
  if guardFail then return guardFail end

  if (useTimeSec == nil) then
    dbot.warn("inv.cli.pass.fn: # of seconds to use the pass is a required parameter")
    inv.cli.pass.usage()
  else
    dbot.debug("CLI: " .. pluginNameCmd .. " pass " .. passNameOrId .. " " .. useTimeSec)
    inv.pass.use(passNameOrId, useTimeSec)
  end -- if
end -- inv.cli.pass.fn


function inv.cli.pass.usage()
  dbot.print("@W    " .. pluginNameCmd .. " pass @G<pass ID> <# of seconds>@w")
end -- inv.cli.pass.usage


function inv.cli.pass.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.pass.usage()

  dbot.print(
[[@W
Some areas require specific items to be in your main inventory in order for you to
pass through certain rooms or doors.  These are not keys.  This plugin refers to
such items as "passes".  A pass is saveable (unlike a key) and can be kept in a
container.

What we want is the ability to quickly pull a pass out of its container, keep it
in the main inventory for a specific period of time, and then put the pass away.
That would allow us to uses passes easily within a mapper cexit operation.

For example, the "Pet Store Employee ID Card" from the area "Giant's Pet Store"
is not a key, is saveable, and is required to access certain rooms.  We use the
"@Gdinv pass [name or ID] [# of seconds]@W" syntax to pull out the Employee Card
at the appropriate time (via a cexit) and then put it away a few seconds later.

Example:
  1) Pull out the pass with the unique ID 1761322232 and hold it in main inventory
     for 3 seconds before putting it back into its original container
     "@Gdinv pass 1761322232 3@W"
]])

end -- inv.cli.pass.examples


inv.cli.consume = {}
function inv.cli.consume.fn(name, line, wildcards)
  local command = wildcards[1] or ""
  local itemType = wildcards[2] or ""
  local itemName = wildcards[3] or ""
  local itemNum = tonumber(itemName)
  local container = wildcards[4] or ""

  dbot.debug("CLI: " .. pluginNameCmd .. " consume command=\"" .. (command or "") .. "\", itemType=\"" ..
             (itemType or "") .. "\", itemName/Num=\"" .. (itemName or "") .. "\", container=\"" ..
             container .. "\"")

  local guardFail = inv.cli.requireReadyStateFor("consume")
  if guardFail then return guardFail end

  if (command == "add") then
    inv.consume.add(itemType, itemName)
  elseif (command == "remove") then
    inv.consume.remove(itemType, itemName)
  elseif (command == "display") then
    inv.consume.display(itemType)
  elseif (command == "buy") then
    inv.consume.buy(itemType, itemNum, container)
  elseif (command == drlConsumeSmall) or (command == drlConsumeBig) then
    inv.consume.use(itemType, command, itemNum, container)
  elseif (command == "autoorganize") then
    inv.cli.consume.autoorganize(itemType)
  elseif (command ~= "") and (inv.consume.table ~= nil) and (inv.consume.table[command] ~= nil) then
    -- Shorthand: "dinv consume <type>" defaults to "dinv consume big <type>"
    inv.consume.use(command, drlConsumeBig, tonumber(itemType) or 1, itemName)
  else
    inv.cli.consume.usage()
  end -- if

end -- inv.cli.consume.fn


function inv.cli.consume.usage()
  dbot.print("@W    " .. pluginNameCmd .. " consume @G[add | remove | display | " ..
             "buy | autoorganize | small | big | <type>] <type or name or quantity> @Y<container>@w")
end -- inv.cli.consume.usage


function inv.cli.consume.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.consume.usage()
  dbot.print(
[[@W
Using consumable items such as potions, pills, and scrolls is a very common
occurrence.  The plugin facilitates this by giving users the ability to specify
types and locations of consumable items.  Users can then ask the plugin to
restock or use particular types of things.  Confused yet?  Let me explain by
giving you a walk-through.

Run to the Aylor potion shop, define a new type of consumable named "@Cfly@W", and
then specify the name of the potion
"@Grecall; runto potion@W"
"@Gdinv consume add fly griff@W"

We can now buy items of type "@Cfly@W".  Let's buy three for now.  We happen to
be starting at the shop already, but we could be anywhere on the mud and the
plugin will try to run us back to the shop before purchasing the item.
"@Gdinv consume buy fly 3@W"

On second thought, let's buy 2 more "@Cfly@W" potions and automatically put
the fly potions in container 3.bag
"@Gdinv consume buy fly 2 3.bag@W"

Let's use a "@Cfly@W" potion!  Don't worry about the "small" option yet.  We'll
explain that shortly.  [EDIT: I just proofread this and nearly choked on my coffee.
Yes, we have an example here that instructs you to consume a small fly.  At least
we stopped before the instructions said to consume a big fly.]
"@Gdinv consume small fly@W"

This looks promising.  Let's add several potions for a new type called "@Cmana@W".
We start with one potion at the Aylor shop and then run to a shop in the Seekers' clan
area.

"@Grecall; runto potion@W"
"@Gdinv consume add mana rush@W"
"@Grecall; runto seekers; e@W"
"@Gdinv consume add mana stem@W"
"@Gdinv consume add mana seed@W"
"@Gdinv consume add mana bud@W"

Let's display all of our consumable types and instances of those types.  The
output shown below is for my favorite set of items.  You can run to whatever shops
you wish and add items of your own choice.  The consumable types that I have
defined include "@Cmove@W", "@Cmana@W", "@Csight@W", "@Cheal@W", and "@Cfly@W.  Some of these such
as "@Cmana@W" and "@Cheal@W" include multiple instances for different levels.  That will
become important later on in this walk-through.
"@Gdinv consume display@W"

@Cfly       @W Level   Room  # Avail  Name
@w               1  32476     @M   3@w  griff
@w
@Cheal      @W Level   Room  # Avail  Name
@w               1  32476        0  light relief
@w              20  32476        0  serious relief
@w              30  14141        0  minor healing
@w              60  14141        0  seekers60heal
@w             201  50209     @M 136@w  frank
@w
@Cmana      @W Level   Room  # Avail  Name
@w               1  32476        0  lotus rush
@w              20  30525        0  nachos
@w              30  14141        0  lotus seed
@w              50  23160        0  tequila
@w              60  14141        0  lotus stem
@w              85  28359        0  alabaster
@w             100  14141        0  lotus bud
@w             130  30525        0  popcorn
@w             150  14141        0  lotus bloom
@w             175  28359        0  diamond
@w             201  14141     @M 154@w  lotus flower
@w
@Cmove      @W Level   Room  # Avail  Name
@w              90  23160     @M   2@w  moonshine
@w
@Csight     @W Level   Room  # Avail  Name
@w               1  32476        0  wolf

Now we want to buy one item of type "@Cheal@W".  Note that this doesn't necessarily
mean that it has the "heal" spell.  It could be any type of potion or pill that
heals us in some way.
"@Gdinv consume buy heal@W"

So...out of all of the options of type "@Cheal@W", which one did the plugin choose?
It will pick the highest level item that is accessible to you at your current
level.  With the consumable table shown above, if you are level 25, it will
pick the Level 20 "serious relief" potion.  If you are level 70, it would buy
the Level 60 "seekers60heal" potion instead.

What's with the "small" and "big" options?  If you are in combat and need to
use a healing potion, you probably want to quaff the biggest and baddest potion
that you have available: "@Gdinv consume big heal@W".  However, if you aren't
in the middle of combat and want to use up some lower-level healing pots that are
just taking up space, you could use the "small" option instead.  That will use up
the lowest-level "@Cheal@W" consumables in your inventory first before moving on to
higher-level items.  If you want to use your three lowest-level items of type "@Cheal@W",
use this: "@Gdinv consume small heal 3@W".

As a shorthand, "@Gdinv consume <type>@W" (e.g., "@Gdinv consume heal@W") is equivalent
to "@Gdinv consume big <type>@W".  This is the most common use case -- use the best
available item for your current level.

The plugin supports Potions (quaff), Pills (eat), Scrolls (recite), and Food (eat).

The plugin will always choose to consume items that are in your main inventory
before using an equivalent item from a container unless you specify a container.

I find it very convenient to list which consumable items I actually have in my inventory.
As a result, you can use "@Gdinv consume display owned@W" as a shorthand to suppress the
display output for items you do not currently have in your inventory or containers.

Examples:
  1) Add a consumable item ("nachos") that gives something of type "mana".  Nachos
     can be found at "runto bard; run wn" and you should be at the shopkeeper to
     use this command.
     "@Gdinv consume add mana nachos@W"

  2) Remove "nachos" from the "mana" consumable type table
     "@Gdinv consume remove mana nachos@W"

  3) Remove the consumable type "mana" and everything that is that type
     "@Gdinv consume remove mana@W"

  4) Display info about all consumable items in the table regardless of type
     "@Gdinv consume display@W"

  5) Display info about each consumable item that is of type "mana"
     "@Gdinv consume display mana@W"

  6) Display info about each consumable item that is currently in your inventory
     "@Gdinv consume display owned@W"

  7) Buy 5 "mana" items that are the highest level available in the table
     "@Gdinv consume buy mana 5@W"

  8) Buy 10 "heal" items and put them into 3.bag
     "@Gdinv consume buy heal 10 3.bag@W"

  9) Consume (quaff, eat, etc.) the lowest level "mana" item in your inventory
     This is useful when you want to clean out low-level potions.  You probably won't
     use this option in combat but it is convenient out of combat.
    "@Gdinv consume small mana@W"

 10) Consume (quaff, eat, etc.) 2 of the highest-level items in your inventory that
     are of type "mana".  This is handy in combat.
     "@Gdinv consume big mana 2@W"

 11) Consume 3 of your highest-level mana items and look in container 2.bag before
     checking for the items in other locations
     "@Gdinv consume big mana 3 2.bag@W"

 12) Set a default container for purchased consumables.  After this, every
     "@Gdinv consume buy@W" command will automatically put bought items into 2.bag
     unless you specify a different container on the command line.
     "@Gdinv consume autoorganize 2.bag@W"

 13) Display the current auto-organize container setting
     "@Gdinv consume autoorganize@W"

 14) Disable auto-organize for purchased consumables
     "@Gdinv consume autoorganize off@W"
]])

end -- inv.cli.consume.examples


function inv.cli.consume.autoorganize(param)
  param = param or ""

  if (param == "") then
    -- Display current setting
    local current = inv.config.table.consumeBuyContainer or ""
    if (current == "") then
      dbot.info("Auto-organize for bought consumables is @RDISABLED@W")
    else
      dbot.info("Auto-organize for bought consumables is @GENABLED@W: container = \"@C" ..
                current .. "@W\"")
    end -- if
    return DRL_RET_SUCCESS

  elseif (param == "off") or (param == "clear") then
    -- Disable
    inv.config.table.consumeBuyContainer = ""
    dbot.info("Auto-organize for bought consumables is @RDISABLED@W")
    return inv.config.save()

  else
    -- Set container
    inv.config.table.consumeBuyContainer = param
    dbot.info("Bought consumables will be auto-organized into \"@C" .. param .. "@W\"")
    return inv.config.save()
  end -- if
end -- inv.cli.consume.autoorganize


inv.cli.organize = {}
function inv.cli.organize.fn1(name, line, wildcards)
  local command     = wildcards[1] or ""
  local container   = wildcards[2] or ""
  local queryString = wildcards[3] or ""
  local endTag      = inv.tags.new(line)

  dbot.debug("CLI: " .. pluginNameCmd .. " organize command=\"" .. (command or "") .. "\", container=\"" ..
             container .. "\", query=\"" .. queryString .. "\"")

  local guardFail = inv.cli.requireReadyStateFor("organize")
  if guardFail then return inv.tags.stop(invTagsOrganize, endTag, guardFail) end

  if (command == "add") then
    inv.items.organize.add(container, queryString, endTag)
  elseif (command == "clear") then
    inv.items.organize.clear(container, endTag)
  else
    inv.cli.organize.usage()
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_INVALID_PARAM)
  end -- if

end -- inv.cli.organize.fn1


function inv.cli.organize.fn2(name, line, wildcards)
  local command = wildcards[1] or ""
  local endTag  = inv.tags.new(line)

  dbot.debug("CLI: " .. pluginNameCmd .. " organize command=\"" .. (command or "") .. "\"")

  local guardFail = inv.cli.requireReadyStateFor("organize")
  if guardFail then return inv.tags.stop(invTagsOrganize, endTag, guardFail) end

  if (command ~= "display") then
    inv.cli.organize.usage()
    return inv.tags.stop(invTagsOrganize, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  inv.items.organize.display(endTag)
end -- inv.cli.organize.fn2


function inv.cli.organize.fn3(name, line, wildcards)
  local queryString = wildcards[1] or ""
  local endTag      = inv.tags.new(line)

  dbot.debug("CLI: " .. pluginNameCmd .. " organize query=\"" .. queryString .. "\"")

  local guardFail = inv.cli.requireReadyStateFor("organize")
  if guardFail then return inv.tags.stop(invTagsOrganize, endTag, guardFail) end

  inv.items.organize.cleanup(queryString, endTag)
end -- inv.cli.organize.fn3


function inv.cli.organize.usage()
  dbot.print("@W    " .. pluginNameCmd .. " organize @G[add | clear | display] " ..
             "@Y<container relative name or ID> <query>@w")
end -- inv.cli.organize.usage


function inv.cli.organize.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.organize.usage()
  dbot.print(
[[@W
The "@Gdinv put ...@W" and "@Gdinv store ...@W" modes are incredibly convenient for putting items
away into containers.  However, wouldn't it be even more convenient if you could assign
one or more queries to each container and automagically store items matching those queries
into their respective containers?  The "@Corganize@W" mode gives you this ability.

You can add search queries (see "@Gdinv help search@W" for query details and examples) to
containers.  You can also display or clear out a container's queries.

Once you assign search queries to containers, you can specify one or more items in your
inventory with a search query.  The plugin will check all items matching your query to see if
they would also match an "organize" query for a container.  If an item matches both queries,
the plugin moves it to that container.

It's up to you to ensure that multiple containers don't match the same item(s) in an organize
request.  If an item could be organized into two different containers, it will eventually end
up in one, but there are no guarantees as to which of the containers it will be.  For example,
if you assign all quest items to one container and all portals to another container, the
aardwolf amulet will match both the quest container and the portal container in an organize
request and it could end up in either container.

You may flag containers as "ignored" to prevent dinv from accessing items in those containers.
See the "@Gdinv help ignore@W" helpfile for instructions and examples.

Let's get to some examples!

  1) Specify that all potions and pills belong in container 3.bag
     "@Gdinv organize add 3.bag type potion || type pill@W"

  2) Organize all potions and pills by moving them to 3.bag (as specified in the previous
     example).
     "@Gdinv organize type potion || type pill@W"

  3) In my personal setup, I have one bag for potions and pills, another bag for portals, a
     third bag for weapons, armor, and lights between levels 1 - 160, and a fourth bag for
     weapons, armor, and lights with a level of 161 or higher.  Some quest items are flagged
     as type "treasure" instead of type "armor" -- even if they clearly are armor.  As a result
     I also added "|| key aardwolf ..." to the equipment bags so that they also pick up the
     (mislabeled?) armor.  Doing this adds a conflict with the aardwolf amulet though because
     it matches both the portal container and the aardwolf quest equipment container.  That is
     why I added a "~key aardwolf" query to the portal container.

Let's see what that looks like:
     "@Gdinv organize display@W"

@WContainers that have associated organizational queries:
@W  "a @YBag of @RAardwolf@W": @Ctype potion || type pill
@W  "a @YBag of @RAardwolf@W": @Ctype portal @-key aardwolf
@W  "a @YBag of @RAardwolf@W": @Ctype armor maxlevel 160 || type weapon maxlevel 160 || type light maxlevel@C 160 || key aardwolf maxlevel 160
@W  "a @YBag of @RAardwolf@W": @Ctype armor minlevel 161 || type weapon minlevel 161 || type light minlevel@C 161 || key aardwolf minlevel 161
@W
  4) If I want to put everything away, I would use an empty search query to match everything
     in my inventory.  Bingo.  Everything is now tucked away in containers.  This will also put
     away your worn equipment so you may want to take an equipment snapshot or ensure you have
     a priority set available to re-wear your equipment before you do this.
     "@Gdinv organize@W"

  5) You can clear a container's organize queries like this:
     "@Gdinv organize clear 3.bag@W"

  6) Here is how you would organize just your aardwolf quest weapons:
     "@Gdinv organize type weapon keyword aardwolf@W"

  7) If you want to organize a specific item by using a relative name, you could do
     something like this:
     "@Gdinv organize rname 3.cloak@W"

  8) If you just want to organize all items with "sword" in their names, you can use the
     fact that queries assume keys are names by default:
     "@Gdinv organize sword@W"
]])

end -- inv.cli.organize.examples


inv.cli.version = {}
function inv.cli.version.fn(name, line, wildcards)
  local command = wildcards[1] or ""
  local retval  = DRL_RET_SUCCESS
  local endTag  = inv.tags.new(line)

  dbot.debug("CLI: command=\"" .. command .. "\"")

  if (not inv.init.initializedActive) then
    dbot.info("Skipping version request: plugin is not yet initialized (are you AFK or sleeping?)")
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_UNINITIALIZED)

  elseif (command == "") then
    retval = inv.version.display()
    return inv.tags.stop(invTagsVersion, endTag, retval)

  elseif (not dbot.gmcp.stateIsActive()) then
    dbot.info("Skipping version request: character is not in the active state")
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_NOT_ACTIVE)

  elseif (command == "changelog") then
    dbot.info("Full changelog:")
    retval = dbot.version.changelog.get(0, endTag) -- show changelog from version 0 to the latest

  elseif (command == "check") then
    retval = dbot.version.update.release(drlDbotUpdateCheck, endTag)

  else
    retval = dbot.version.update.release(drlDbotUpdateInstall, endTag)

  end -- if

  return retval
end -- inv.cli.version.fn


function inv.cli.version.usage()
  dbot.print("@W    " .. pluginNameCmd .. " version @Y[check | changelog | update confirm]@w")
end -- inv.cli.version.usage


function inv.cli.version.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.version.usage()
  dbot.print(
[[@W
The version mode without arguments will tell you the version information for the
plugin and format versions for components of the plugin.  You can also check if
you have the latest official plugin release and optionally view the changelog
between your current version and the latest version.  If you wish to upgrade to
the latest release, you can do that too :)

Examples:
  1) Display your current version information
     "@Gdinv version@W"

  2) Compare your plugin version to the version of the latest published release
     and display the changelog between your version and the latest release
     "@Gdinv version check@W"

  3) Display the entire plugin changelog
     "@Gdinv version changelog@W"

  4) Check if you have the latest plugin version.  If your version is not the
     latest and greatest, download the latest release and install it.  You do
     not need to log out or restart mush.
     "@Gdinv version update confirm@W"
]])

end -- inv.cli.version.examples


inv.cli.help = {}
function inv.cli.help.fn(name, line, wildcards)
  local command = wildcards[1] or ""
  local endTag  = inv.tags.new(line)

  dbot.debug("inv.cli.help.fn: command=\"" .. command .. "\"")

  if (inv.cli[command] ~= nil) and (inv.cli[command].examples ~= nil) then
    inv.cli[command].examples()
  else
    inv.cli.fullUsage()
  end -- if

  inv.tags.stop(invTagsHelp, endTag, DRL_RET_SUCCESS)
end -- inv.cli.help.fn


function inv.cli.help.usage()
  dbot.print("@W    " .. pluginNameCmd .. " help @Y<command>@w")
end -- inv.cli.help.usage


function inv.cli.help.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.help.usage()
  dbot.print(
[[@W
Run "@Gdinv help@W" by itself to see a list of this plugin's modes.  You can
pick any of the modes and see more details and examples by running this:
"@Gdinv help [something]@W".

Examples:
  1) Learn about building an inventory table
     "@Gdinv help build@W"

  2) Read the helpfile for analyzing equipment sets
     "@Gdinv help analyze@W"

]])

end -- inv.cli.help.examples


inv.cli.report = {}
function inv.cli.report.fn(name, line, wildcards)
  local reportChannel = wildcards[1] or ""
  local reportType    = wildcards[2] or ""
  local reportArgs    = wildcards[3] or ""

  local retval = DRL_RET_SUCCESS

  if (reportChannel == "") then
    dbot.warn("inv.cli.report.fn: Missing target channel")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (reportType == "set") then
    local _, _, priName, priLevel = string.find(reportArgs, "([^ ]+)[ ]+(%d+)[ ]*")

    if (priName == nil) or (priLevel == nil) then
      _, _, priName = string.find(reportArgs, "([^ ]+)")
    end -- if

    dbot.debug("priName=\"" .. (priName or "nil") .. "\", priLevel=\"" .. (priLevel or "nil") .. "\"")
    inv.set.display(priName, priLevel, reportChannel, nil)

  elseif (reportType == "item") then
    local relName = string.gsub(reportArgs, "[ ]+.*", "")
    return inv.report.item(reportChannel, relName)

  else
    dbot.warn("inv.cli.report.fn: Invalid report type \"" .. (reportType or "nil") .. "\"")
    return DRL_RET_INVALID_PARAM
  end -- if

  return DRL_RET_SUCCESS
end -- inv.cli.report.fn


function inv.cli.report.usage()
  dbot.print("@W    " .. pluginNameCmd ..
             " report @G<channel> [item <relative name> | set <priority> @Y(level)@G]@w")
end -- inv.cli.report.usage


function inv.cli.report.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.report.usage()
  dbot.print(
[[@W
The @Creport@W mode allows you to report a short summary of an item or set to a channel.
To report an item, you must either know the item's unique ID or have the item in your
main inventory.

Examples:
  1) Echo a summary description of 2.dagger to yourself
     "@Gdinv report echo item 2.dagger@W"

  2) Brag about your new aura to your group
     "@Gdinv report gtell item aura@W"

  3) Advertise a kai on barter
     "@Gdinv report barter item 3.kai@W"

  4) Use an item's unique ID instead of a relative name
     "@Gdinv report clantalk item 12345678@W"

  5) Report a set summary to your group for priority psi-melee
     "@Gdinv report gtell set psi-melee@W"

  6) Report an estimated set summary for priority psi-melee at level 100
     "@Gdinv report echo set psi-melee 100@W"
]])

end -- inv.cli.report.examples


inv.cli.migrate = {}
function inv.cli.migrate.fn(name, line, wildcards)
  local command = Trim(wildcards[1] or "")
  local endTag  = inv.tags.new(line)

  dbot.debug("inv.cli.migrate.fn: command=\"" .. command .. "\"")

  if (not inv.init.initializedActive) then
    dbot.info("Skipping migrate request: plugin is not yet initialized (are you AFK or sleeping?)")
    inv.tags.stop(invTagsMigrate, endTag, DRL_RET_UNINITIALIZED)
    return
  end

  if (command == "") then
    -- Show detection results
    local detection = inv.migrate.detect()

    if not detection.found then
      if not detection.dir then
        dbot.info("Could not determine old aard_inventory state directory.")
        dbot.info("Ensure you are logged into a character that had aard_inventory data.")
      else
        dbot.info("No old aard_inventory state files found for this character.")
        dbot.info("Checked directory: " .. detection.dir)
      end
      inv.tags.stop(invTagsMigrate, endTag, DRL_RET_MISSING_ENTRY)
      return
    end

    dbot.print("\n@C  Old aard_inventory data detected@w")
    dbot.print("@W  " .. string.rep("-", 50) .. "@w")
    dbot.print("@W  Directory: @G" .. detection.dir .. "@w\n")

    for _, f in ipairs(detection.files) do
      if f.exists then
        dbot.print("@W    " .. string.format("%-16s", f.desc) .. " @GFound@w")
      else
        dbot.print("@W    " .. string.format("%-16s", f.desc) .. " @xNot found@w")
      end
    end

    dbot.print("")
    dbot.print("@R  WARNING: @WMigration will replace ALL current dinv data for this character.@w")
    dbot.print("@W  A backup of the current database will be created automatically.@w")
    dbot.print("@W  Old aard_inventory state files will NOT be modified.@w\n")
    dbot.print("@W  To proceed, type: @Gdinv migrate confirm@w\n")
    inv.tags.stop(invTagsMigrate, endTag, DRL_RET_SUCCESS)

  elseif (command == "confirm") then
    local retval = inv.migrate.execute()
    inv.tags.stop(invTagsMigrate, endTag, retval)

  else
    inv.cli.migrate.usage()
    inv.tags.stop(invTagsMigrate, endTag, DRL_RET_INVALID_PARAM)
  end

end -- inv.cli.migrate.fn


function inv.cli.migrate.usage()
  dbot.print("@W    " .. pluginNameCmd .. " migrate @Y[confirm]@w")
end -- inv.cli.migrate.usage


function inv.cli.migrate.examples()
  dbot.print("@W\nUsage:\n")
  inv.cli.migrate.usage()
  dbot.print(
[[@W
The @Cmigrate@W command imports data from the old aard_inventory plugin into dinv.
This is a one-time operation for players switching from aard_inventory to dinv.

Run "@Gdinv migrate@W" by itself to see what old data is available for migration.
Run "@Gdinv migrate confirm@W" to execute the migration.

@RIMPORTANT:@W Migration @Rreplaces all current dinv data@W for the current character.
A backup of the current database is created automatically before migration.
Your old aard_inventory state files are never modified.

@CWhat is migrated:@w
  Items, priorities, equipment sets, consumables, stat bonuses, and
  configuration settings. Caches, tags, and wish data are skipped
  (they rebuild automatically during normal use).

@CMulti-character support:@w
  Migration operates on the currently logged-in character only. If you
  have multiple characters with aard_inventory data, log into each one
  and run "@Gdinv migrate confirm@W" separately.

@CReverting to aard_inventory:@w
  If you decide to switch back, remove dinv and reinstall aard_inventory.
  Your old state files are untouched. A migration tool from dinv back to
  aard_inventory is not provided.

Examples:
  1) Check what old data is available for the current character.
     "@Gdinv migrate@W"

  2) Run the migration.
     "@Gdinv migrate confirm@W"

  3) If something goes wrong, restore from the pre-migration backup.
     "@Gdinv backup restore pre-migrate@W"
]])

end -- inv.cli.migrate.examples


inv.cli.commlog = {}
function inv.cli.commlog.fn(name, line, wildcards)
  local msg = Trim(wildcards[1] or "")
  local outerColor = "@x105"
  local innerColor = "@x39"

  dbot.debug("Commlog message = \"" .. msg .. "\"")

  dbot.commLog(outerColor .. "[" .. innerColor .. "DINV" .. outerColor .. "]@w " .. msg .. "@w")

end -- inv.cli.commlog.fn


inv.cli.debug = {}
function inv.cli.debug.fn(name, line, wildcards)
  local params = Trim(wildcards[1] or "")

  dbot.note("Debug params = \"" .. params .. "\"")

  dbot.commLog("[DINV] " .. params)

end -- inv.cli.debug.fn


inv.cli.catchall = {}
function inv.cli.catchall.fn(name, line, wildcards)
  dbot.info("Invalid dinv command: \"" .. (line or "nil") .. "\"")
  inv.cli.fullUsage()
end -- inv.cli.debug.fn


