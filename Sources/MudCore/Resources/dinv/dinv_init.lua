
----------------------------------------------------------------------------------------------------
-- Plugin Information
----------------------------------------------------------------------------------------------------

pluginNameCmd   = "dinv"
pluginNameAbbr  = "DINV"
pluginId        = "731f94b0f2b54345f836bbaf"


----------------------------------------------------------------------------------------------------
-- External dependencies
----------------------------------------------------------------------------------------------------

require "wait"
require "check"
require "serialize"
require "tprint"
require "gmcphelper"
require "async"
require "json"

dofile(GetInfo(60) .. "aardwolf_colors.lua")

math.randomseed(os.time())

-- Plugin directory for loading additional modules
dinv_plugin_dir = GetPluginInfo(GetPluginID(), 20)


----------------------------------------------------------------------------------------------------
-- Plugin state path
--
-- We need a path to the state directory for this plugin.  Ideally, we would just use the path
-- returned by GetInfo(85) and be done.  Unfortuately, GetInfo(85) returns a relative path on
-- some mush installations.  This means that the path may or may not be valid depending on what
-- mush thinks your current directory is.  A relative path may be correct during normal plugin
-- execution but be wrong during the OnPluginSaveState() call because that call has a different
-- current directory than what is used while the plugin is running.  Ugh.  This is further
-- complicated by inconsistencies across systems where some mush installs use absolute paths for
-- your state directory while other installations use relative paths.  Double ugh.
--
-- Our solution is to start with the state directory and check if it is a relative or absolute
-- path.  If it is relative it should be relative to our current directory.  Fortunately, we
-- have access to an absolute path to the current directory via GetInfo(64).  If we concatenate
-- the current directory and relative state directory, we should have an absolute path to the
-- state directory.  On the other hand, if the state directory is an absolute path, we can just
-- use that without modification.

-----------------------------------------------------------------------------------------------------

function drlGetPluginStatePath()
  local path      = ""
  local stateBase = GetInfo(85) or ""
  local stateDir  = stateBase .. pluginNameCmd .. "-" .. pluginId

  if (stateBase == nil) or (stateBase == "") then
    print("drlGetPluginStatePath: Error: Failed to get state path")

  elseif (string.find(stateDir, "^[.]") ~= nil) then
    -- The path starts with "." so it must be relative
    path = GetInfo(64) .. stateDir

  else
    path = stateDir
  end -- if

  -- Some versions of windows don't like if a path has something like "foo\.\bar" in it.  This
  -- strips out any redundant ".\" in the path if it exists.
  path = string.gsub(path, "\\.\\", "\\")

  return path
end -- drlGetPluginStatePath


pluginStatePath = drlGetPluginStatePath() or ""
--print("Plugin state path: \"" .. pluginStatePath .. "\"")


----------------------------------------------------------------------------------------------------
-- Mushclient plugin callbacks
----------------------------------------------------------------------------------------------------

function OnPluginInstall()

  dbot.debug("OnPluginInstall!")

  local retval = inv.reload(drlDoSaveState)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("OnPluginInstall: Failed to load/reload plugin: " .. dbot.retval.getString(retval))
  end -- if

end -- OnPluginInstall


-- You might think that this would be a great place to de-init the plugin.  Unfortunately,
-- MUSHclient calls OnPluginSaveState AFTER calling OnPluginClose.  This means that the state
-- won't save properly if we fully de-init our data and clean things up.  Bummer.  Instead, we
-- currently use a somewhat convoluted scheme duplicating code in OnPluginDisconnect and in
-- the inv.reload() function called by OnPluginInstall.
--
-- I'm leaving this here as a placeholder for now.  Maybe we could use it for something in the
-- future.
function OnPluginClose()
  dbot.debug("OnPluginClose")
end -- OnPluginClose


-- There currently isn't a need for this callback in our plugin.  This is just a placeholder for now.
function OnPluginWorldSave()
  dbot.debug("OnPluginWorldSave")
end -- OnPluginWorldSave


function OnPluginSaveState()
  local retval

  dbot.debug("OnPluginSaveState!")

  -- We can't save state if GMCP isn't initialized because we don't know which character's state
  -- we need to save or where to save it
  if (dbot.gmcp.isInitialized == false) then
    return
  end -- if

  -- We also can't save state if we aren't initialized yet
  if (not dbot.init.initializedActive) then
    dbot.debug("OnPluginSaveState: Skipping save because plugin is not yet initialized")
    local charState = dbot.gmcp.getState() or "Uninitialized"
    if (charState ~= dbot.stateActive) then
      dbot.info("You must be in the active state to save your data but your state is \"@C" ..
                dbot.gmcp.getStateString(charState) .. "@W\"")
    end -- if
    return
  end -- if

  -- The inv and dbot modules always call the appropriate *.save() function as soon as possible
  -- when saved state needs to be updated.  However, it doesn't hurt to be a bit paranoid and
  -- allow the user to explicitly save plugin state here.

  -- Save state of all inventory modules
  for module in inv.modules:gmatch("%S+") do
    if (inv[module].save ~= nil) then
      retval = inv[module].save()
      if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
        dbot.warn("OnPluginSaveState: Failed to save state for inv." .. module .. " module: " ..
                  dbot.retval.getString(retval))
      end -- if
    end -- if
  end -- for

  -- Save state of all dbot modules
  for module in dbot.modules:gmatch("%S+") do
    if (dbot[module].save ~= nil) then
      retval = dbot[module].save()
      if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
        dbot.warn("OnPluginSaveState: Failed to save state for dbot." .. module .. " module: " ..
                  dbot.retval.getString(retval))
      end -- if
    end -- if
  end -- for

end -- OnPluginSaveState


function OnPluginConnect()
  dbot.debug("OnPluginConnect!")

  -- If we aren't initialized yet, initialize everything...Yes, this technically isn't "install time"
  -- but it is close enough for our purposes.  The important thing is that we don't try to init any
  -- "at active" things such as loading saved state.  We don't know which char's state to load until
  -- the user logs in and GMCP can give us the username.
  if (inv.init.initializedInstall == false) then
    local retval = inv.init.atInstall()
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("OnPluginConnect: Failed to init \"at install\" inventory code: " ..
                dbot.retval.getString(retval))
    end -- if
  end -- if

end -- OnPluginConnect


function OnPluginDisconnect()
  dbot.debug("OnPluginDisconnect!")

  local retval = inv.fini(drlDoSaveState)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("OnPluginDisconnect: Failed to de-init the inventory module: " .. dbot.retval.getString(retval))
  end -- if
end -- OnPluginDisconnect


function OnPluginEnable()
  dbot.debug("OnPluginEnable!")
  dbot.info("@GENABLED@W")
end -- OnPluginEnable


function OnPluginDisable()
  dbot.debug("OnPluginDisable!")
  dbot.info("@RDISABLED@W:  You may type \"invmon\" to disable invmon tags if you no longer need them.")
end -- OnPluginDisable


-- We use the telnet subnegotiation protocol to monitor GMCP config status.  Yes, this duplicates
-- some functionality of the gmcphelper plugin, but it provides backwards compatibility (mush r1825
-- doesn't support GMCP config) and it also eliminates synchronization issues with the gmcphelper plugin.
local drlTelnetTypeGMCP = 201
function OnPluginTelnetSubnegotiation (msgType, data)
  if msgType ~= drlTelnetTypeGMCP then
    return
  end -- if

  if (data ~= nil) then
    local mode, params = string.match (data, "([%a.]+)%s+(.*)")

    if (mode == "config") then
      local configKey, configValue = string.match(params, "{ \"([%w_]+)\" : \"([%w_]+)\" }")

      if (configKey ~= nil) and (configValue ~= nil) then
        dbot.debug("GMCP config: key=\"" .. configKey .. "\", value=\"" .. configValue .. "\"")
        dbot.gmcp.currentState[configKey] = configValue
      end -- if
    end -- if
  end -- if

end -- OnPluginTelnetSubnegotiation


function OnPluginTelnetOption(msg)
  if (msg == string.char(100, 1)) then
    dbot.debug("Player is at login screen")

  elseif (msg == string.char(100, 2)) then
    dbot.debug("Player is at MOTD or login sequence")

  elseif (msg == string.char(100, 3)) then
    dbot.debug("Player is fully active!")

    -- We already have code to do the atActive init when we detect that GMCP is alive.  However, it
    -- is also convenient to duplicate it here so that we can attempt to init the moment we come out
    -- of AFK.  This makes the init a little more reponsive than waiting for GMCP.  This could happen
    -- if the user is AFK when they log in and then exits AFK at some indeterminate time in the future.
    if (dbot.gmcp.isInitialized) and (not inv.init.initializedActive) then
      local retval = inv.init.atActive()
      if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_BUSY) then
        dbot.warn("OnPluginTelnetOption: Failed to init \"at active\" inventory modules: " ..
                  dbot.retval.getString(retval))
      end -- if
    end -- if

    -- Kick off a co-routine to handle any post-wakeup operations (e.g., put regen ring away, etc.)
    inv.regen.onWake()

  elseif (msg == string.char(100, 4)) then
    dbot.debug("Player is AFK!")

    -- We keep track of the time between when an "afk" command is sent to the mud and when we actually
    -- go into afk mode.  This is helpful because there is a small window where we want to hold off
    -- on starting an atomic operation if we will shortly be in afk mode.  Once we know we are in AFK
    -- mode, we no longer have a "pending" state.
    dbot.execute.afkIsPending = false

  end -- if

end -- OnPluginTelnetOption


gmcpPluginId = "3e7dedbe37e44942dd46d264"
function OnPluginBroadcast(msg, pluginId, pluginName, text)
  local retval = DRL_RET_SUCCESS

  -- We want to wait to init things until plugins are loaded and the system is stable.  This is
  -- a little ugly, but we wait until the GMCP plugin broadcasts something.  That seems as likely
  -- a time as any for it to be safe for us to init things.  We manually kick GMCP by requesting the
  -- char.base info in the OnPluginInstall() function just to be sure that we are initialized.
  if (pluginId == gmcpPluginId) then
    dbot.debug("OnPluginBroadcast: pluginName = \"" .. (pluginName or "main script") .. "\", text = \"" ..
               text .. "\"")

    -- Once we know GMCP is alive, we allow accesses to it
    if (dbot.gmcp.isInitialized == false) and (text == "char.base") then
      dbot.debug("GMCP base broadcast detected: GMCP is initialized!")
      dbot.gmcp.isInitialized = true

      if dbot.gmcp.stateIsActive() then
        retval = inv.init.atActive()
        if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_BUSY) then
          dbot.warn("OnPluginBroadcast: Failed to init \"at active\" inventory modules: " ..
                    dbot.retval.getString(retval))
        end -- if
      end -- if
    end -- if

  end -- if
end -- OnPluginBroadcast


-- We monitor traffic to the mud in OnPluginSend() in order to scan for a few specific commands.
-- If we find one of the special commands that can impact safe execution calls, then we set an
-- appropriate "pending" flag.  For example, if the plugin sees that an "afk" message is in
-- transit to the mud, we want to let the safe execution framework know that we'll be in the
-- AFK state shortly.
function setPending(msg)

  if (string.lower(msg) == "afk") and (dbot.gmcp.getState() ~= dbot.stateAFK) then
    dbot.execute.afkIsPending = true

  elseif (string.lower(msg) == "quit") then
    dbot.execute.quitIsPending = true

    -- Add a trigger to clear the quitIsPending flag if the quit is cancelled
    AddTriggerEx("drlQuitCancelConfirmationTrigger",
                 "^These items will be lost if you quit. Use .quit quit. if you are sure.$",
                 "dbot.execute.quitIsPending = false",
                 drlTriggerFlagsBaseline + trigger_flag.OneShot,
                 custom_colour.NoChange, 0, "", "", sendto.script, 0)

  elseif (string.lower(msg) == "note write") then
    dbot.execute.noteIsPending = true

    -- Add a trigger to clear the noteIsPending flag once the note starts
    AddTriggerEx("drlNoteWriteConfirmationTrigger",
                 "^("                                                     ..
                    "You are now creating a new post in the .* forum.|"   ..
                    "You are now continuing a new post in the .* forum.|" ..
                    "You cannot post notes in this forum."                ..
                 ")$",
                 "dbot.execute.noteIsPending = false",
                 drlTriggerFlagsBaseline + trigger_flag.OneShot,
                 custom_colour.NoChange, 0, "", "", sendto.script, 0)
  end -- if

end -- setPending


drlLastCmdTime = os.time()
drlIdleTime = 60 * 15 -- 15 minutes of no commands --> we are idle
drlIsIdle = false
function OnPluginSend(msg)

  local baseCommand

  -- Can this ever happen?  I guess it doesn't hurt to be paranoid...
  if (msg == nil) then
    return false
  end -- if

  --dbot.note("@MOnPluginSend@W: Detected request to send \"@G" .. msg .. "@W\"")

  -- If the command has a special "bypass" prefix appended to it, we strip off the prefix
  -- and send it to the mud server immediately no questions asked.  In this case, we return
  -- false because we don't want to send something with the prefix to the mud server.  The
  -- server wouldn't know what to do with that.
  _, _, baseCommand = string.find(msg, dbot.execute.bypassPrefix .. "(.*)")
  if (baseCommand ~= nil) then
    --dbot.note("@mBypass command = @W\"@G" .. (baseCommand or "nil") .. "@W\"")
    -- It is helpful in some scenarios for us to know that something special is pending.  For
    -- example, we might be sending a command to the mud to go AFK, or quit, or write a note.
    setPending(baseCommand)

    check (SendNoEcho(baseCommand))
    return false
  end -- if

  -- We have a valid command entered by the user and not something that the plugin is running
  -- in the background.  If we were in the idle state, drop out of idle and restart the statBonus
  -- background thread.
  drlLastCmdTime = dbot.getTime()
  if drlIsIdle then
    check (AddTimer(inv.statBonus.timer.name, 0, inv.statBonus.timer.min, inv.statBonus.timer.sec, "",
                    timer_flag.Enabled + timer_flag.Replace + timer_flag.OneShot,
                    "inv.statBonus.set"))
    dbot.debug("Restarting stat bonus thread.  We are out of idle!")
    drlIsIdle = false
  end -- if

  -- If we are at this point, then we know that we don't have a "bypass" command.  This means
  -- that we should either queue up the command if we are in a state where we are delaying
  -- command execution, or we should allow the command to go through as normal.
  if dbot.execute.doDelayCommands then
    dbot.execute.queue.pushFast(msg)

    -- We just added a new command to the command queue.  If we don't already have a
    -- co-routine processing commands on that queue, start one now.
    if (not dbot.execute.queue.isDequeueRunning) then
      dbot.execute.queue.isDequeueRunning = true
      wait.make(dbot.execute.queue.dequeueCR)
    end -- if

    return false -- Don't send the command right now

  else
    -- If the user is sending commands, they are not in note mode or quitting
    if dbot.execute.noteIsPending then
      dbot.execute.noteIsPending = false
      dbot.deleteTrigger("drlNoteWriteConfirmationTrigger")
    end
    if dbot.execute.quitIsPending then
      dbot.execute.quitIsPending = false
      dbot.deleteTrigger("drlQuitCancelConfirmationTrigger")
    end

    -- It is helpful in some scenarios for us to know that something special is pending.  For
    -- example, we might be sending a command to the mud to go AFK, or quit, or write a note.
    setPending(msg)

    return true  -- Allow the command to go to the mud server
  end -- if

end -- OnPluginSend


----------------------------------------------------------------------------------------------------
-- Top-level inventory functions
--
-- Functions
--   inv.init.atInstall()    -- add triggers, timers, etc.
--   inv.init.atActive()     -- kick off inv.init.atActiveCR co-routine
--   inv.init.atActiveCR()   -- load tables, etc.
--   inv.fini(doSaveState)   -- remove triggers, save tables, etc.
--   inv.reset(endTag)       -- Reset some or all of the inventory components / modules
--   inv.reload(doSaveState) -- De-init and re-init everything
----------------------------------------------------------------------------------------------------

inv            = {}
inv.init       = {}
inv.modules    = "config items cache priority set statBonus consume snapshot tags"
inv.inSafeMode = false

inv.init.initializedInstall = false
inv.init.initializedActive  = false
inv.init.activePending      = false


drlDoSaveState    = true
drlDoNotSaveState = false


function inv.init.atInstall()
  local retval = DRL_RET_SUCCESS

  -- Initialize all of the "at install" dbot modules (this is a common code framework for multiple plugins)
  if (dbot.init.initializedInstall == false) then
    retval = dbot.init.atInstall()
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.init.atInstall: Failed to initialize \"at install\" dbot modules: " ..
                dbot.retval.getString(retval))
    else
      dbot.init.initializedInstall = true
    end -- if
  end -- if

  if inv.init.initializedInstall then
    dbot.note("Skipping inv.init.atInstall request: it is already initialized")
    return retval
  end -- if

  -- We aren't running the discovery or identification processes yet
  inv.state = invStateIdle

  -- Loop through all of the "at install" inv modules and call their init functions
  retval = DRL_RET_SUCCESS
  if (inv.init.initializedInstall == false) then
    for module in inv.modules:gmatch("%S+") do
      if (inv[module].init.atInstall ~= nil) then
        local initVal = inv[module].init.atInstall()
        if (initVal ~= DRL_RET_SUCCESS) then
          dbot.warn("inv.init.atInstall: Failed to initialize \"at install\" inv." .. module ..
                    " module: " .. dbot.retval.getString(initVal))
          retval = initVal
        else
          dbot.debug("Initialized \"at install\" module inv." .. module)
        end -- if
      end -- if
    end -- for

    if (retval == DRL_RET_SUCCESS) then
      inv.init.initializedInstall = true
    end -- if
  end -- if

  -- We need access to GMCP in order to determine our state in some circumstances.  If we start
  -- mush from scratch, then we can determine our state via OnPluginTelnetOption.  Easy Peasy.
  -- However, if we manually reinstall the plugin, then our plugin may have missed the output from
  -- OnPluginTelnetOption and we don't know what our state is.  We can get that from GMCP, but we
  -- don't know if GMCP is available yet and querying the gmcp plugin will crash if it's not in
  -- an initialized state.  So...what do we do?  We wait for OnPluginBroadcast to detect that GMCP
  -- is up and running.  We'd rather not wait too long to detect this though so we nudge things
  -- along by asking GMCP to send out the char data.  We can detect this broadcast and know that
  -- GMCP is alive when the broadcast arrives.
  Send_GMCP_Packet("request char")

  -- Return success or the most recently encountered init error
  return retval

end -- inv.init.atInstall


-- This is only called when we know we are in the active state.  Many of the actions we take
-- at the "active" state involve waiting for results so we use a co-routine to handle all of
-- the "at active" operations.
function inv.init.atActive()
  local retval = DRL_RET_SUCCESS

  if (not inv.init.activePending) then
    inv.init.activePending = true
    wait.make(inv.init.atActiveCR)
  else
    dbot.debug("inv.init.atActive: Another initialization is in progress")
    retval = DRL_RET_BUSY
  end -- if

  return retval
end -- inv.init.atActive


function inv.init.atActiveCR()
  local retval = DRL_RET_SUCCESS

  if (dbot.gmcp.isInitialized == false) then
    dbot.error("inv.init.atActiveCR: GMCP is not initialized when we are active!?!")
    inv.init.activePending = false
    return DRL_RET_INTERNAL_ERROR
  end -- if

  -- Initialize all of the "at active" dbot modules (this is a common code framework for multiple plugins)
  if (dbot.init.initializedActive == false) then
    retval = dbot.init.atActive()
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.init.atActiveCR: Failed to initialize \"at active\" dbot modules: " ..
                dbot.retval.getString(retval))
    else
      dbot.debug("Initialized dbot \"at active\" modules")
      dbot.init.initializedActive = true

      -- Open SQLite database
      if not dinv_db.open() then
        dbot.error("inv.init.atActiveCR: Failed to open SQLite database. Plugin cannot initialize.")
        inv.init.activePending = false
        return DRL_RET_INTERNAL_ERROR
      end
    end -- if
  end -- if

  -- Initialize all of the "at active" inventory modules
  retval = DRL_RET_SUCCESS
  if (inv.init.initializedActive == false) then
    for module in inv.modules:gmatch("%S+") do
      if (inv[module].init.atActive ~= nil) then
        local initVal = inv[module].init.atActive()
        if (initVal ~= DRL_RET_SUCCESS) then
          dbot.warn("inv.init.atActiveCR: Failed to initialize \"at active\" inv." .. module ..
                    " module: " .. dbot.retval.getString(initVal))
          retval = initVal
        else
          dbot.debug("Initialized \"at active\" module inv." .. module)
        end -- if
      end -- if
    end -- for

    if (retval == DRL_RET_SUCCESS) then
      inv.init.initializedActive = true
      local fullVer = string.format("%d.%04d", inv.version.pluginMajor, inv.version.pluginMinor)
      dbot.info("Plugin version " .. fullVer .. " is fully initialized")

      -- Kick off an immediate full inventory refresh so that we have an accurate view of what
      -- the user has.  They may have logged in without using the plugin and moved things around
      -- or added and removed items.  Ideally, we would do this at every login.  However, some
      -- users may have refreshes disabled because they want to handle things manually.  That's
      -- fine too.  If refreshes are disabled (their period is 0 minutes) then we skip this.
      if (inv.items.refreshGetPeriods() > 0) then
        dbot.info("Running initial full scan to check if your inventory was modified outside of this plugin")
        dbot.info("Prompts will be disabled until the scan completes")
        local endTag = inv.tags.new(nil, "Completed initial refresh full scan", nil, inv.tags.cleanup.timed)
        retval = inv.items.refresh(0, invItemsRefreshLocAll, endTag, nil)
        if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
           dbot.info("Initial full inventory rescan could not complete: " .. dbot.retval.getString(retval))
           dbot.info("Please run \"@Gdinv refresh all@W\" to ensure the plugin knows that you didn't do " ..
                     "something evil like logging in via telnet to move items around :P")
        end -- if
      end -- if
    end -- if
  end -- if

  -- Return success or the most recently encountered init error
  inv.init.activePending = false
  return retval

end -- inv.init.atActiveCR


-- Force every module's in-memory state to SQLite WITHOUT de-initializing.
-- Used by dbot.backup.create immediately before it closes the DB and copies
-- the file -- otherwise pending in-memory mutations (lazy-seeded stat bonuses,
-- weaponSet exclusions from "dinv weapon use", anything else not yet
-- persisted per-mutation) would be missing from the backup, and "dinv backup
-- restore" would silently produce a state strictly older than what was on
-- screen when the backup was taken.  Cheap modules (config, consume, tags)
-- always run; expensive wholesale rewrites (items, cache) only matter for
-- the rare case where per-mutation save was bypassed.
function inv.flush()
  if not dbot.gmcp.isInitialized then return DRL_RET_UNINITIALIZED end

  for module in inv.modules:gmatch("%S+") do
    if inv[module] and type(inv[module].save) == "function" then
      local rv = inv[module].save()
      if (rv ~= DRL_RET_SUCCESS) and (rv ~= DRL_RET_UNINITIALIZED) then
        dbot.warn("inv.flush: inv." .. module .. ".save returned " .. dbot.retval.getString(rv))
      end
    end
  end

  for module in dbot.modules:gmatch("%S+") do
    if dbot[module] and type(dbot[module].save) == "function" then
      local rv = dbot[module].save()
      if (rv ~= DRL_RET_SUCCESS) and (rv ~= DRL_RET_UNINITIALIZED) then
        dbot.warn("inv.flush: dbot." .. module .. ".save returned " .. dbot.retval.getString(rv))
      end
    end
  end

  return DRL_RET_SUCCESS
end


function inv.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  -- Stop automatic refreshes as we de-init things
  inv.state = invStateHalted

  if dbot.gmcp.isInitialized then
    -- Loop through all of the inv modules and call their de-init functions
    for module in inv.modules:gmatch("%S+") do
      local initVal = inv[module].fini(doSaveState)

      if (initVal ~= DRL_RET_SUCCESS) and (initVal ~= DRL_RET_UNINITIALIZED) then
        dbot.warn("inv.fini: Failed to de-initialize inv." .. module .. " module: " ..
                  dbot.retval.getString(initVal))
        retval = initVal
      else
        dbot.debug("De-initialized inv module \"" .. module .. "\"")
      end -- if
    end -- for

    -- De-init all of the dbot modules (common framework code for multiple plugins)
    retval = dbot.fini(doSaveState)
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("init.fini: De-initialization of dbot module failed: " .. dbot.retval.getString(retval))
    end -- if

    -- Close SQLite database
    dinv_db.close()
  end -- if

  -- This indicates that we are now uninitialized
  inv.init.initializedInstall = false
  inv.init.initializedActive  = false
  inv.init.activePending      = false
  inv.state = nil

  -- Return success or the most recently encountered de-init error
  return retval

end -- inv.fini


-- Takes a string containing module names to reset (e.g., "items config portal cache")
function inv.reset(moduleNames, endTag)
  local retval = DRL_RET_SUCCESS
  local numModulesReset = 0

  if (moduleNames == nil) or (moduleNames == "") then
    dbot.warn("inv.reset: missing module names to reset")
  end -- if

  if (moduleNames == "all") then
    moduleNames = inv.modules
  end -- if

  -- Loop through all of the module names in the list and attempt to reset each module with a
  -- corresponding name
  for moduleName in moduleNames:gmatch("%S+") do
    if dbot.isWordInString(moduleName, inv.modules) then
      dbot.note("Resetting module \"@C" .. moduleName .. "@W\"")
      local currentRetval = inv[moduleName].reset()

      -- Remember the most recent error so that we can return it
      if (currentRetval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.reset: Failed to reset module \"@C" .. moduleName .. "@W\": " ..
                  dbot.retval.getString(currentRetval))
        retval = currentRetval
      else
        numModulesReset = numModulesReset + 1
      end -- if
    else
      dbot.warn("inv.reset: Attempted to reset invalid module name \"@C" .. moduleName .. "@W\"")
      retval = DRL_RET_MISSING_ENTRY
    end -- if
  end -- for

  local suffix = ""
  if (numModulesReset ~= 1) then
    suffix = "s"
  end -- if

  dbot.info("Successfully reset " .. numModulesReset .. " module" .. suffix)

  return inv.tags.stop(invTagsReset, endTag, retval)
end -- inv.reset


function inv.reload(doSaveState)
  local retval = DRL_RET_SUCCESS

  -- De-init the plugin if it is already initialized.  This could happen if we restore state from
  -- a backup and want to re-init everything
  if inv.init.initializedInstall then
    dbot.note("inv.reload: Reinitializing plugin")

    retval = inv.fini(doSaveState)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.reload: Failed to de-initialize inventory module: " ..
                dbot.retval.getString(retval))
    end -- if
  end -- if

  -- Init everything that we can at "install time".  This typically would entail adding triggers,
  -- timers, and aliases.  We don't want to try loading saved state here though (that's at "active time")
  -- because we need GMCP initialized to get the user's name in order to get the correct user's state.
  retval = inv.init.atInstall()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.reload: Failed to init \"at install\" inventory code: " ..
              dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.reload


----------------------------------------------------------------------------------------------------
-- Versions of the plugin and plugin components
--
-- Functions:
--   inv.version.get()
--   inv.version.display()
--
-- Data:
--    inv.version.table
----------------------------------------------------------------------------------------------------

inv.version = {}

inv.version.full = GetPluginInfo(GetPluginID(), 19)
inv.version.pluginMajor = math.floor(inv.version.full)
inv.version.pluginMinor = tonumber(string.format("%.4f", (inv.version.full - inv.version.pluginMajor) * 10000))

inv.version.table = { pluginVer      = { major = inv.version.pluginMajor, minor = inv.version.pluginMinor },
                      tableFormat    = { major = 0, minor = 1 },
                      cacheFormat    = { major = 0, minor = 1 },
                      consumeFormat  = { major = 0, minor = 1 },
                      priorityFormat = { major = 0, minor = 1 },
                      setFormat      = { major = 0, minor = 1 },
                      snapshotFormat = { major = 0, minor = 1 }
                    }


function inv.version.get()
  return inv.version.table
end -- inv.version.get


function inv.version.display()
  dbot.print("\n  @y" .. pluginNameAbbr .. "  Aardwolf Plugin\n" ..
                "-------------------------@w")
  dbot.print("@WPlugin Version:    @G" ..
             string.format("%01d", inv.version.table.pluginVer.major) .. "." ..
             string.format("%04d", inv.version.table.pluginVer.minor) .. "@w")
  dbot.print("")
  dbot.print("@WInv. Table Format: @G" ..
             inv.version.table.tableFormat.major .. "." ..
             inv.version.table.tableFormat.minor .. "@w")
  dbot.print("@WInv. Cache Format: @G" ..
             inv.version.table.cacheFormat.major .. "." ..
             inv.version.table.cacheFormat.minor .. "@w")
  dbot.print("@WConsumable Format: @G" ..
             inv.version.table.consumeFormat.major .. "." ..
             inv.version.table.consumeFormat.minor .. "@w")
  dbot.print("@WPriorities Format: @G" ..
             inv.version.table.priorityFormat.major .. "." ..
             inv.version.table.priorityFormat.minor .. "@w")
  dbot.print("@WEquip Set Format:  @G" ..
             inv.version.table.setFormat.major .. "." ..
             inv.version.table.setFormat.minor .. "@w")
  dbot.print("@WSnapshot Format:   @G" ..
             inv.version.table.snapshotFormat.major .. "." ..
             inv.version.table.snapshotFormat.minor .. "@w")
  dbot.print("")

  return DRL_RET_SUCCESS
end -- inv.version.display


----------------------------------------------------------------------------------------------------
-- Versions of the plugin and plugin components
--
-- Functions:
--   inv.config.init.atActive()
--   inv.config.fini(doSaveState)
--
--   inv.config.save()
--   inv.config.load()
--   inv.config.reset()
--   inv.config.new()
--
-- Data:
--    inv.config.table
--    inv.config.stateName  -- name for file holding state in persistent storage
----------------------------------------------------------------------------------------------------

inv.config           = {}
inv.config.init      = {}
inv.config.table     = {}


function inv.config.init.atActive()
  local retval = DRL_RET_SUCCESS

  retval = inv.config.load()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.config.init.atActive: failed to load config data from storage: " ..
              dbot.retval.getString(retval))
  end -- if

  -- It's possible that we previously disabled the prompt and could not re-enable it.  For example,
  -- maybe the user closed mushclient in the middle of a refresh.  In that case, we wouldn't have the
  -- opportunity to turn the prompt back on.  As a result, we keep track of the user's prompt state
  -- and put it back to the last known value here if the current state doesn't match what we expect.
  if (inv.config.table.isPromptEnabled ~= nil) and
     (inv.config.table.isPromptEnabled ~= dbot.prompt.isEnabled) then
    dbot.info("Prompt state does not match expected state: toggling prompt")

    -- We don't use an execute.safe call here because we haven't finished initializing and the safe
    -- execution framework requires us to be fully initialized.
    dbot.execute.fast.command("prompt")
    dbot.execute.queue.fence()
  end -- if

  inv.regen.init()

  return retval
end -- inv.config.init.atActive


function inv.config.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  -- Save our current data
  if (doSaveState) then
    retval = inv.config.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.config.fini: Failed to save inv.config module data: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  return retval
end -- inv.config.fini


function inv.config.save()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  local t = inv.config.table
  if not t then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM config WHERE key LIKE 'config.%'")

    -- Serialize version subtables as strings
    local function verStr(v)
      if type(v) == "table" then
        return tostring(v.major or 0) .. "." .. tostring(v.minor or 0)
      end
      return tostring(v or "")
    end

    local fields = {
      ["config.pluginVer"]       = verStr(t.pluginVer),
      ["config.tableFormat"]     = verStr(t.tableFormat),
      ["config.cacheFormat"]     = verStr(t.cacheFormat),
      ["config.consumeFormat"]   = verStr(t.consumeFormat),
      ["config.priorityFormat"]  = verStr(t.priorityFormat),
      ["config.setFormat"]       = verStr(t.setFormat),
      ["config.snapshotFormat"]  = verStr(t.snapshotFormat),
      ["config.isPromptEnabled"] = tostring(t.isPromptEnabled),
      ["config.isBuildExecuted"] = tostring(t.isBuildExecuted),
      ["config.doIgnoreKeyring"] = tostring(t.doIgnoreKeyring),
      ["config.isRegenEnabled"]  = tostring(t.isRegenEnabled),
      ["config.regenOrigObjId"]  = tostring(t.regenOrigObjId or 0),
      ["config.regenNewObjId"]   = tostring(t.regenNewObjId or 0),
      ["config.refreshPeriod"]   = tostring(t.refreshPeriod or 0),
      ["config.refreshEagerSec"] = tostring(t.refreshEagerSec or 0),
      ["config.consumeBuyContainer"] = tostring(t.consumeBuyContainer or ""),
    }

    for k, v in pairs(fields) do
      local query = string.format("INSERT INTO config (key, value) VALUES (%s, %s)",
                                  dinv_db.fixsql(k), dinv_db.fixsql(v))
      db:exec(query)
      if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
        dbot.warn("inv.config.save: Failed to save config key " .. k)
        return DRL_RET_INTERNAL_ERROR
      end
    end

    return DRL_RET_SUCCESS
  end)
end -- inv.config.save


function inv.config.load()
  local db = dinv_db.handle
  if not db then
    inv.config.reset()
    return DRL_RET_SUCCESS
  end

  -- Check if any config rows exist
  local count = 0
  for row in db:nrows("SELECT COUNT(*) as cnt FROM config WHERE key LIKE 'config.%'") do
    count = row.cnt
  end

  if count == 0 then
    -- No saved config — initialize with defaults
    inv.config.reset()
    return DRL_RET_SUCCESS
  end

  -- Load config values into a lookup table
  local vals = {}
  for row in db:nrows("SELECT key, value FROM config WHERE key LIKE 'config.%'") do
    vals[row.key] = row.value
  end

  -- Helper to parse version strings back to tables
  local function parseVer(s)
    if not s or s == "" then return { major = 0, minor = 0 } end
    local maj, min = s:match("^(%d+)%.(%d+)$")
    if maj then return { major = tonumber(maj), minor = tonumber(min) } end
    return { major = 0, minor = 0 }
  end

  local function toBool(s)
    return s == "true"
  end

  inv.config.table = {
    pluginVer       = parseVer(vals["config.pluginVer"]),
    tableFormat     = parseVer(vals["config.tableFormat"]),
    cacheFormat     = parseVer(vals["config.cacheFormat"]),
    consumeFormat   = parseVer(vals["config.consumeFormat"]),
    priorityFormat  = parseVer(vals["config.priorityFormat"]),
    setFormat       = parseVer(vals["config.setFormat"]),
    snapshotFormat  = parseVer(vals["config.snapshotFormat"]),
    isPromptEnabled = toBool(vals["config.isPromptEnabled"]),
    isBuildExecuted = toBool(vals["config.isBuildExecuted"]),
    doIgnoreKeyring = toBool(vals["config.doIgnoreKeyring"]),
    isRegenEnabled  = toBool(vals["config.isRegenEnabled"]),
    regenOrigObjId  = tonumber(vals["config.regenOrigObjId"]) or 0,
    regenNewObjId   = tonumber(vals["config.regenNewObjId"]) or 0,
    refreshPeriod   = tonumber(vals["config.refreshPeriod"]) or 0,
    refreshEagerSec = tonumber(vals["config.refreshEagerSec"]) or 0,
    consumeBuyContainer = vals["config.consumeBuyContainer"] or "",
  }

  return DRL_RET_SUCCESS
end -- inv.config.load


function inv.config.reset()
  inv.config.table = inv.config.new()

  local retval = inv.config.save()
  if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("inv.config.reset: Failed to save configuration data: " .. dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.config.reset


function inv.config.new()
  local version = inv.version.get()

  return { pluginVer       = version.pluginVer,
           tableFormat     = version.tableFormat,
           cacheFormat     = version.cacheFormat,
           consumeFormat   = version.consumeFormat,
           priorityFormat  = version.priorityFormat,
           setFormat       = version.setFormat,
           snapshotFormat  = version.snapshotFormat,

           isPromptEnabled = true,
           isBuildExecuted = false,
           doIgnoreKeyring = false,
           isRegenEnabled  = false,
           regenOrigObjId  = 0,
           regenNewObjId   = 0,
           refreshPeriod   = 0,
           refreshEagerSec = 0,
           consumeBuyContainer = ""
         }
end -- inv.config.new




----------------------------------------------------------------------------------------------------
-- Load dinv modules
----------------------------------------------------------------------------------------------------

dofile(dinv_plugin_dir .. "dinv_db.lua")
dofile(dinv_plugin_dir .. "dinv_cli.lua")
dofile(dinv_plugin_dir .. "dinv_items.lua")
dofile(dinv_plugin_dir .. "dinv_report.lua")
dofile(dinv_plugin_dir .. "dinv_data.lua")
dofile(dinv_plugin_dir .. "dinv_cache.lua")
dofile(dinv_plugin_dir .. "dinv_priority.lua")
dofile(dinv_plugin_dir .. "dinv_score.lua")
dofile(dinv_plugin_dir .. "dinv_set.lua")
dofile(dinv_plugin_dir .. "dinv_equipment.lua")
dofile(dinv_plugin_dir .. "dinv_statbonus.lua")
dofile(dinv_plugin_dir .. "dinv_analyze.lua")
dofile(dinv_plugin_dir .. "dinv_usage.lua")
dofile(dinv_plugin_dir .. "dinv_unused.lua")
dofile(dinv_plugin_dir .. "dinv_tags.lua")
dofile(dinv_plugin_dir .. "dinv_consume.lua")
dofile(dinv_plugin_dir .. "dinv_portal.lua")
dofile(dinv_plugin_dir .. "dinv_regen.lua")
dofile(dinv_plugin_dir .. "dinv_migrate.lua")


----------------------------------------------------------------------------------------------------
-- Load dbot framework
----------------------------------------------------------------------------------------------------

dofile(dinv_plugin_dir .. "dinv_dbot.lua")
