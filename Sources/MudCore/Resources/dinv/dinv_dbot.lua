----------------------------------------------------------------------------------------------------
-- Base module
----------------------------------------------------------------------------------------------------

dbot = {}


----------------------------------------------------------------------------------------------------
-- Init / de-init routines for the dbot package
--
-- Some modules should be initialized at "install" time.  Others should be initialized only once
-- the user is at the "active" state after a login.
--
-- Triggers, timers, and aliases most likely should be initialized at "install" time.
--
-- Loading state most likely should be done at "active" time (because we need the username to get
-- the correct state and the username isn't available at install time)
--
-- dbot.init.atInstall()
-- dbot.init.atActive()
-- dbot.fini(doSaveState)
--
----------------------------------------------------------------------------------------------------

dbot.init = {}

dbot.init.initializedInstall = false
dbot.init.initializedActive  = false

-- gmcp should be last (so we can save data)
dbot.modules = "emptyLine backup notify prompt invmon wish execute pagesize gmcp"


function dbot.init.atInstall()
  local retval = DRL_RET_SUCCESS

  -- Loop through all of the dbot modules that need to be initialized at "install" time and then call
  -- the init functions of those modules
  for module in dbot.modules:gmatch("%S+") do
    if (dbot[module].init.atInstall ~= nil) then
      local initVal = dbot[module].init.atInstall()
      if (initVal ~= DRL_RET_SUCCESS) then
        dbot.warn("dbot.init.atInstall: Failed to initialize \"at install\" dbot." .. module .. " module: " ..
                  dbot.retval.getString(initVal))
        retval = initVal
      else
        dbot.debug("Initialized \"at install\" module dbot." .. module)
      end -- if
    end -- if

  end -- for

  -- Return success or the most recently encountered init error
  return retval
end -- dbot.init.atInstall


function dbot.init.atActive()
  local retval = DRL_RET_SUCCESS

  -- Loop through all of the dbot modules that need to be initialized when the user is at the "active"
  -- state and call those modules' init functions
  for module in dbot.modules:gmatch("%S+") do
    if (dbot[module].init.atActive ~= nil) then
      local initVal = dbot[module].init.atActive()
      if (initVal ~= DRL_RET_SUCCESS) then
        dbot.warn("dbot.init.atActive: Failed to initialize \"at active\" dbot." .. module .. " module: " ..
                  dbot.retval.getString(initVal))
        retval = initVal
      else
        dbot.debug("Initialized \"at active\" module dbot." .. module)
      end -- if
    end -- if
  end -- for

  -- Return success or the most recently encountered init error
  return retval
end -- dbot.init.atActive


function dbot.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  -- Loop through all of the dbot modules and call their de-init functions
  for module in dbot.modules:gmatch("%S+") do
    if (dbot[module].fini ~= nil) then
      local initVal = dbot[module].fini(doSaveState)
      if (initVal ~= DRL_RET_SUCCESS) and (initVal ~= DRL_RET_UNINITIALIZED) then
        dbot.warn("dbot.fini: Failed to de-initialize dbot." .. module .. " module: " ..
                  dbot.retval.getString(initVal))
        retval = initVal
      else
        dbot.debug("De-initialized dbot module \"" .. module .. "\"")
      end -- if

      dbot.debug("De-initialized module dbot." .. module)
    end -- if
  end -- for

  dbot.init.initializedInstall = false
  dbot.init.initializedActive  = false

  return retval
end -- dbot.fini


----------------------------------------------------------------------------------------------------
-- dbot.print: Basic print function that supports color codes
--
-- This accepts strings that include aard, xterm, and ANSI color codes
--
-- Examples:
--   "@Wthis is white"
--   DRL_ANSI_RED .. "this is red"
--   DRL_XTERM_YELLOW .. "this is yellow"
----------------------------------------------------------------------------------------------------

function dbot.print(string)
  -- Only print the string to the output if we are not in the middle of writing a note.  If GMCP
  -- isn't initialized yet, assume that we aren't writing a note and display the message.
  if (dbot.gmcp.isInitialized == false) or (dbot.gmcp.getState() ~= dbot.stateNote) then
    AnsiNote(stylesToANSI(ColoursToStyles(string)))
  end -- if
end -- dbot.print


----------------------------------------------------------------------------------------------------
-- dbot.getTime returns the native time in seconds
----------------------------------------------------------------------------------------------------

function dbot.getTime()
  return tonumber(os.time()) or 0
end -- dbot.getTime


----------------------------------------------------------------------------------------------------
-- dbot.reload: Reloads the current plugin
--
-- Note: This code was derived from part of a plugin by Arcidayne.  Thanks Arcidayne!
----------------------------------------------------------------------------------------------------

function dbot.reload()
  local scriptPrefix = GetAlphaOption("script_prefix")
  local retval

  -- If the user has not already specified the script prefix for this version of mush, pick a
  -- reasonable default value
  if (scriptPrefix == "") then
    scriptPrefix = "\\\\\\"
    SetAlphaOption("script_prefix", scriptPrefix)
  end

  -- Tell mush to reload the plugin in one second.  We can't do it directly here because a
  -- plugin can't unload itself.  Even if it could, how could it tell mush to load it again
  -- if it weren't installed?
  retval = Execute(scriptPrefix.."DoAfterSpecial(1, \"ReloadPlugin('"..GetPluginID().."')\", sendto.script)")
  if (retval ~= 0) then
    dbot.warn("dbot.reload: Failed to reload the plugin: mush error " .. retval)
    retval = DRL_RET_INTERNAL_ERROR
  end -- if

  return retval
end -- dbot.reload


----------------------------------------------------------------------------------------------------
-- dbot.shell: Run a shell command in the background without pulling up a command prompt window
----------------------------------------------------------------------------------------------------

function dbot.shell(shellCommand)
  local retval = DRL_RET_SUCCESS
  local mushRetval

  if (shellCommand == nil) or (shellCommand == "") then
    dbot.warn("dbot.shell: Missing shell command")
    return DRL_RET_INVALID_PARAM
  end -- if

  dbot.debug("dbot.shell: Executing \"@G" .. "/C " .. shellCommand .. "@W\"")

  local ok, error = utils.shellexecute("cmd", "/C " .. shellCommand, GetInfo(64), "open", 0)
  if (not ok) then
    dbot.warn("dbot.shell: Command \"@G" .. shellCommand .. "@W\" failed")
    retval = DRL_RET_INTERNAL_ERROR
  end -- if

  return retval
end -- dbot.shell


----------------------------------------------------------------------------------------------------
-- dbot.fileExists: Returns true if the specified file (or directory) exists and false otherwise
----------------------------------------------------------------------------------------------------

function dbot.fileExists(fileName)
  if (fileName == nil) or (fileName == "") then
    return false
  end -- if

  local dirQuery = string.gsub(string.gsub(fileName, "\\", "/"), "/$", "")
  local dirTable, error = utils.readdir(dirQuery)

  if (dirTable == nil) then
    return false
  else
    --tprint(dirTable)
    return true
  end -- if

end -- dbot.fileExists


----------------------------------------------------------------------------------------------------
-- dbot.tonumber: version of tonumber that strips out commas from a number
----------------------------------------------------------------------------------------------------

function dbot.tonumber(numString)
  local noCommas = string.gsub(numString, ",", "")
  return tonumber(noCommas)
end -- dbot.tonumber


----------------------------------------------------------------------------------------------------
-- dbot.isWordInString: Returns boolean indicating if the word (separated by spaces) in in the
--                      specified string
----------------------------------------------------------------------------------------------------

function dbot.isWordInString(word, field)
  if (word == nil) or (word == "") or (field == nil) or (field == "") then
    return false
  end -- if

  for element in field:gmatch("%S+") do
    if (string.lower(word) == string.lower(element)) then
      return true
    end -- if
  end -- for

  return false
end -- dbot.isWordInString


----------------------------------------------------------------------------------------------------
-- dbot.wordsToArray: converts a string into an array of individual white-space separated words
--
-- Returns array, retval
----------------------------------------------------------------------------------------------------

function dbot.wordsToArray(myString)
  local wordTable = {}

  if (myString == nil) then
    dbot.warn("dbot.wordsToArray: Missing string parameter")
    return wordTable, DRL_RET_INVALID_PARAM
  end -- if

  for word in string.gmatch(myString, "%S+") do
    table.insert(wordTable, word)
  end -- for

  return wordTable, DRL_RET_SUCCESS
end -- dbot.wordsToArray


----------------------------------------------------------------------------------------------------
-- dbot.mergeFields: Returns a string containing all of the unique words in the two input parameters
--
-- For example: merging "hello world" and "goodbye world" would yield "hello world goodbye"
----------------------------------------------------------------------------------------------------

function dbot.mergeFields(field1, field2)
  local mergedField = field1 or ""

  if (field2 ~= nil) and (field2 ~= "") then
    for word in field2:gmatch("%S+") do
      if (not dbot.isWordInString(word, field1)) then
        mergedField = mergedField .. " " .. word
      end -- if
    end -- for
  end -- if

  return mergedField
end -- dbot.mergeFields


----------------------------------------------------------------------------------------------------
-- dbot.arrayConcat: Returns an array generated by concatenating the two input arrays
--
-- For example: concatenating { "a", "b", "c" } and { "d", "e" } yields { "a", "b", "c", "d", "e" }
----------------------------------------------------------------------------------------------------
function dbot.arrayConcat(array1, array2)
  local mergedArray = {}

  if (array1 ~= nil) then
    for _, entry in ipairs(array1) do
      table.insert(mergedArray, entry)
    end -- for
  end -- if

  if (array2 ~= nil) then
    for _, entry in ipairs(array2) do
      table.insert(mergedArray, entry)
    end -- for
  end -- if

  return mergedArray
end -- dbot.arrayConcat


----------------------------------------------------------------------------------------------------
-- dbot.isPhysical and dbot.isMagical return booleans indicating if the input parameter string is
-- one of the known physical or magical damage types
----------------------------------------------------------------------------------------------------

dbot.physicalTypes = { invStatFieldBash,    invStatFieldPierce,   invStatFieldSlash }
dbot.magicalTypes =  { invStatFieldAcid,    invStatFieldCold,     invStatFieldEnergy,
                       invStatFieldHoly,    invStatFieldElectric, invStatFieldNegative,
                       invStatFieldShadow,  invStatFieldMagic,    invStatFieldAir,
                       invStatFieldEarth,   invStatFieldFire,     invStatFieldLight,
                       invStatFieldMental,  invStatFieldSonic,    invStatFieldWater,
                       invStatFieldDisease, invStatFieldPoison }

function dbot.isPhysical(damType)
  for _, physType in ipairs(dbot.physicalTypes) do
    if (physType == damType) then
      return true
    end -- if
  end -- for

  return false
end -- dbot.isPhysical


function dbot.isMagical(damType)
  for _, magType in ipairs(dbot.magicalTypes) do
    if (magType == damType) then
      return true
    end -- if
  end -- for

  return false
end -- dbot.isMagical


----------------------------------------------------------------------------------------------------
-- dbot.deleteTrigger: Wrapper around DeleteTrigger that checks the mush error codes
----------------------------------------------------------------------------------------------------

function dbot.deleteTrigger(name)
  local retval = DRL_RET_SUCCESS

  if (name == nil) or (name == "") then
    dbot.warn("dbot.deleteTrigger: Attempted to delete a trigger missing a name")
    return DRL_RET_INVALID_PARAM
  end -- if

  local mushRetval = IsTrigger(name)
  if (mushRetval == error_code.eOK) then
    check (DeleteTrigger(name))
    retval = DRL_RET_SUCCESS

  elseif (mushRetval == error_code.eTriggerNotFound) then
    -- We don't consider it an error if we try to delete a trigger that isn't instantiated.  Our
    -- de-init code tries to whack all triggers without checking if they exist or not.
    retval = DRL_RET_SUCCESS

  elseif (mushRetval == error_code.eInvalidObjectLabel) then
    dbot.warn("dbot.deleteTrigger: Failed to delete trigger: trigger name \"" .. name ..
              "\" isn't a valid label")
    retval = DRL_RET_INVALID_PARAM

  else
    dbot.warn("dbot.deleteTrigger: Detected unknown error code " .. mushRetval)
    retval = DRL_RET_INTERNAL_ERROR
  end -- if

  return retval
end -- dbot.deleteTrigger


----------------------------------------------------------------------------------------------------
-- dbot.deleteTimer: Wrapper around DeleteTimer that checks the mush error codes
----------------------------------------------------------------------------------------------------

function dbot.deleteTimer(name)
  local retval = DRL_RET_SUCCESS

  if (name == nil) or (name == "") then
    dbot.warn("dbot.deleteTimer: Attempted to delete a timer missing a name")
    return DRL_RET_INVALID_PARAM
  end -- if

  local mushRetval = IsTimer(name)
  if (mushRetval == error_code.eOK) then
    DeleteTimer(name)
    retval = DRL_RET_SUCCESS

  elseif (mushRetval == error_code.eTimerNotFound) then
    -- We don't consider it an error if we try to delete a timer that isn't instantiated.  Our
    -- de-init code tries to whack all timers without checking if they exist or not.
    retval = DRL_RET_SUCCESS

  elseif (mushRetval == error_code.eInvalidObjectLabel) then
    dbot.warn("dbot.deleteTimer: Failed to delete timer: timer name \"" .. name .. "\" isn't a valid label")
    retval = DRL_RET_INVALID_PARAM

  else
    dbot.warn("dbot.deleteTimer: Detected unknown error code " .. mushRetval)
    retval = DRL_RET_INTERNAL_ERROR
  end -- if

  return retval
end -- dbot.deleteTimer


----------------------------------------------------------------------------------------------------
-- dbot.commLog sends the given string parameter to the communication log window
----------------------------------------------------------------------------------------------------

function dbot.commLog(msg)
  local clPlugin   = "b555825a4a5700c35fa80780"
  local clFunction = "storeFromOutside"

  if (msg == nil) or (msg == "") then
    dbot.warn("dbot.commLog: Missing message parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  local retval = DRL_RET_INTERNAL_ERROR
  local mushRetval = CallPlugin(clPlugin, clFunction, msg)

  if (mushRetval == error_code.eNoSuchPlugin) then
    dbot.warn("dbot.commLog: target plugin does not exist")

  elseif (mushRetval == error_code.ePluginDisabled) then
    dbot.warn("dbot.commLog: target plugin is disabled")

  elseif (mushRetval == error_code.eNoSuchRoutine) then
    dbot.warn("dbot.commLog: target routine does not exist")

  elseif (mushRetval == error_code.eErrorCallingPluginRoutine) then
    dbot.warn("dbot.commLog: error calling plugin routine")

  elseif (mushRetval == error_code.eBadParameter) then
    dbot.warn("dbot.commLog: bad parameter detected")
    retval = DRL_RET_INVALID_PARAM

  elseif (mushRetval == error_code.eOK) then
    retval = DRL_RET_SUCCESS

  else
    dbot.warn("dbot.commLog: Unknown return value from CallPlugin: " .. (mushRetval or "nil"))

  end -- if

  return retval
end -- dbot.commLog


----------------------------------------------------------------------------------------------------
-- dbot.retval: Return values (AKA error codes)
--
-- Functions:
--   dbot.retval.getString(retval)
--
-- Data:
--   dbot.retval.table  -- this is an in-memory static table that is not saved to persistent storage
----------------------------------------------------------------------------------------------------

DRL_RET_SUCCESS        =  0
DRL_RET_UNINITIALIZED  = -1
DRL_RET_INVALID_PARAM  = -2
DRL_RET_MISSING_ENTRY  = -3
DRL_RET_BUSY           = -4
DRL_RET_UNSUPPORTED    = -5
DRL_RET_TIMEOUT        = -6
DRL_RET_HALTED         = -7
DRL_RET_INTERNAL_ERROR = -8
DRL_RET_UNIDENTIFIED   = -9
DRL_RET_NOT_ACTIVE     = -10
DRL_RET_IN_COMBAT      = -11
DRL_RET_VER_MISMATCH   = -12


dbot.retval = {}
dbot.retval.table = {}
dbot.retval.table[DRL_RET_SUCCESS]        = "success"
dbot.retval.table[DRL_RET_UNINITIALIZED]  = "component is not initialized"
dbot.retval.table[DRL_RET_INVALID_PARAM]  = "invalid parameter"
dbot.retval.table[DRL_RET_MISSING_ENTRY]  = "missing entry"
dbot.retval.table[DRL_RET_BUSY]           = "resource is in use"
dbot.retval.table[DRL_RET_UNSUPPORTED]    = "unsupported feature"
dbot.retval.table[DRL_RET_TIMEOUT]        = "timeout"
dbot.retval.table[DRL_RET_HALTED]         = "component is halted"
dbot.retval.table[DRL_RET_INTERNAL_ERROR] = "internal error"
dbot.retval.table[DRL_RET_UNIDENTIFIED]   = "item is not yet identified"
dbot.retval.table[DRL_RET_NOT_ACTIVE]     = "you are not in the active state"
dbot.retval.table[DRL_RET_IN_COMBAT]      = "you are in combat!"
dbot.retval.table[DRL_RET_VER_MISMATCH]   = "version mismatch"


function dbot.retval.getString(retval)
  local string = dbot.retval.table[retval]

  if (string == nil) then
    string = "Unknown return value"
  end -- if

  return string
end -- dbot.retval.getString


----------------------------------------------------------------------------------------------------
-- dbot.table.getCopy(origTable)
--   Returns a copy of the original table
--   Derived from: http://lua-users.org/wiki/CopyTable
----------------------------------------------------------------------------------------------------

dbot.table = {}
function dbot.table.getCopy(origItem)
  local newItem

  if type(origItem) == 'table' then
    newItem = {}

    for origKey, origValue in next, origItem, nil do
      newItem[dbot.table.getCopy(origKey)] = dbot.table.getCopy(origValue)
    end -- for
    setmetatable(newItem, dbot.table.getCopy(getmetatable(origItem)))
  else
    newItem = origItem
  end -- if

  return newItem
end -- dbot.table.getCopy


----------------------------------------------------------------------------------------------------
-- We can't use #someTable to get the number of entries in it like we can do for an array.
-- This function counts the number of entries in a table and returns the count.
----------------------------------------------------------------------------------------------------

function dbot.table.getNumEntries(theTable)
  local numEntries = 0

  if (theTable ~= nil) then
    for k,v in pairs(theTable) do
      numEntries = numEntries + 1
    end -- for
  end -- if

  return numEntries
end -- dbot.table.getNumEntries


----------------------------------------------------------------------------------------------------
-- Baseline trigger flags
----------------------------------------------------------------------------------------------------

drlTriggerFlagsBaseline = trigger_flag.Enabled + trigger_flag.RegularExpression + trigger_flag.Replace


----------------------------------------------------------------------------------------------------
-- Spin-loops are common.  This is the default time period to sleep after each loop.
----------------------------------------------------------------------------------------------------

drlSpinnerPeriodDefault = 0.1


----------------------------------------------------------------------------------------------------
-- dbot: Color code definitions
----------------------------------------------------------------------------------------------------

DRL_COLOR_GREEN  = "46"
DRL_COLOR_RED    = "160"
DRL_COLOR_YELLOW = "226"
DRL_COLOR_WHITE  = "231"
DRL_COLOR_GREY   = "255"

DRL_XTERM_GREEN  = "@x" .. DRL_COLOR_GREEN
DRL_XTERM_RED    = "@x" .. DRL_COLOR_RED
DRL_XTERM_YELLOW = "@x" .. DRL_COLOR_YELLOW
DRL_XTERM_WHITE  = "@x" .. DRL_COLOR_WHITE
DRL_XTERM_GREY   = "@x" .. DRL_COLOR_GREY

-- Older versions of mush severely broke color codes.  This gives a work-around for those versions.
drlMushClientVersion = tonumber(Version() or "")
if (drlMushClientVersion ~= nil) and (drlMushClientVersion < 5.06) then
  DRL_ANSI_GREEN  = ANSI(DRL_COLOR_GREEN)
  DRL_ANSI_RED    = ANSI(DRL_COLOR_RED)
  DRL_ANSI_YELLOW = ANSI(DRL_COLOR_YELLOW)
  DRL_ANSI_WHITE  = ANSI(DRL_COLOR_WHITE)
else
  -- TODO: Yes, these aren't really ANSI color codes but it make the rest of the code compatible
  --       with the ANSI work-arounds.  At some point, I'd love to stop supporting old 4.x
  --       mush builds and then we could remove all of the ANSI color references in this plugin.
  DRL_ANSI_GREEN  = "@G"
  DRL_ANSI_RED    = "@R"
  DRL_ANSI_YELLOW = "@Y"
  DRL_ANSI_WHITE  = "@W"
end -- if

----------------------------------------------------------------------------------------------------
-- Notification Module
--
-- This provides wrapper functions to print various notification messages.  If we are in "Note"
-- mode (i.e., we are writing a note) we suppress all of these notifications.  Otherwise, we
-- print all warnings and errors and any debug, note, and info messages that are above the
-- user-supplied threshold.  This lets a user change the verbosity of the plugin at runtime.  If
-- a problem is happening, they could enable everything including debug messages.  Once they are
-- comfortable with the plugin, they could suppress lower-priority messages and only leave the
-- highest priority notifications enabled.  If they are particularly brave, they could disable
-- all optional messages and only leave warnings and errors on.
--
-- dbot.notify.init.atActive()
-- dbot.notify.fini(doSaveState)
--
-- dbot.notify.save()
-- dbot.notify.load()
-- dbot.notify.reset()
--
-- dbot.notify.msg
-- dbot.notify.getLevel
-- dbot.notify.setLevel(value, endTag, isVerbose)
--
-- dbot.debug
-- dbot.note
-- dbot.info
-- dbot.warn
-- dbot.error
--
----------------------------------------------------------------------------------------------------

dbot.notify        = {}
dbot.notify.init   = {}
dbot.notify.prefix = pluginNameAbbr

drlDbotNotifyUserLevelNone     = "none"
drlDbotNotifyUserLevelLight    = "light"
drlDbotNotifyUserLevelStandard = "standard"
drlDbotNotifyUserLevelAll      = "all"

notifyLevelDefault = drlDbotNotifyUserLevelStandard

notifyLevelDebug = "DEBUG"
notifyLevelNote  = "NOTE"
notifyLevelInfo  = "INFO"
notifyLevelWarn  = "WARN"
notifyLevelError = "ERROR"

dbot.notify.level = {}
dbot.notify.level[notifyLevelDebug] = { enabled = false, bg = "black", fg = "orange" }
dbot.notify.level[notifyLevelNote]  = { enabled = true,  bg = "white", fg = "green"  }
dbot.notify.level[notifyLevelInfo]  = { enabled = true,  bg = "white", fg = "blue"   }
dbot.notify.level[notifyLevelWarn]  = { enabled = true,  bg = "black", fg = "yellow" }
dbot.notify.level[notifyLevelError] = { enabled = true,  bg = "white", fg = "red"    }


function dbot.notify.init.atActive()
  local retval

  retval = dbot.notify.load()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.notify.init.atActive: Failed to load notify data from storage: " ..
              dbot.retval.getString(retval))
  end -- if

  retval = dbot.notify.setLevel(dbot.notify.table.notifyLevel, nil, false)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.notify.init.atActive: Failed to set notify level from storage: " ..
              dbot.retval.getString(retval))
  end -- if

  return retval
end -- dbot.notify.init.atActive


function dbot.notify.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  if (doSaveState) then
    retval = dbot.notify.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("dbot.notify.fini: Failed to save notify data to storage: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  return retval
end -- dbot.notify.fini


function dbot.notify.save()
  if (dbot.notify.table == nil) then
    return dbot.notify.reset()
  end -- if

  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM config WHERE key = 'notify.level'")
    local query = string.format("INSERT INTO config (key, value) VALUES ('notify.level', %s)",
                                dinv_db.fixsql(dbot.notify.table.notifyLevel or notifyLevelDefault))
    db:exec(query)
    if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
      dbot.warn("dbot.notify.save: Failed to save notify level")
      return DRL_RET_INTERNAL_ERROR
    end

    return DRL_RET_SUCCESS
  end)
end -- dbot.notify.save


function dbot.notify.load()
  local db = dinv_db.handle
  if not db then
    dbot.notify.reset()
    return DRL_RET_SUCCESS
  end

  local level = nil
  for row in db:nrows("SELECT value FROM config WHERE key = 'notify.level'") do
    level = row.value
  end

  if level then
    dbot.notify.table = { notifyLevel = level }
  else
    dbot.notify.reset()
  end

  return DRL_RET_SUCCESS
end -- dbot.notify.load


function dbot.notify.reset()
  dbot.notify.table = { notifyLevel = notifyLevelDefault }

  local retval = dbot.notify.save()
  if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("dbot.notify.reset: Failed to save notification data: " .. dbot.retval.getString(retval))
  end -- if

  return retval
end -- dbot.notify.reset


function dbot.notify.setLevel(value, endTag, isVerbose)

  if (value == drlDbotNotifyUserLevelNone) then
    dbot.notify.level[notifyLevelDebug].enabled = false
    dbot.notify.level[notifyLevelNote].enabled  = false
    dbot.notify.level[notifyLevelInfo].enabled  = false

  elseif (value == drlDbotNotifyUserLevelLight) then
    dbot.notify.level[notifyLevelDebug].enabled = false
    dbot.notify.level[notifyLevelNote].enabled  = false
    dbot.notify.level[notifyLevelInfo].enabled  = true

  elseif (value == drlDbotNotifyUserLevelStandard) then
    dbot.notify.level[notifyLevelDebug].enabled = false
    dbot.notify.level[notifyLevelNote].enabled  = true
    dbot.notify.level[notifyLevelInfo].enabled  = true

  elseif (value == drlDbotNotifyUserLevelAll) then
    dbot.notify.level[notifyLevelDebug].enabled = true
    dbot.notify.level[notifyLevelNote].enabled  = true
    dbot.notify.level[notifyLevelInfo].enabled  = true

  else
    dbot.warn("dbot.notify.setLevel: invalid value parameter")
    return inv.tags.stop(invTagsNotify, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (isVerbose) then
    dbot.info("Set notification level to \"@C" .. value .. "@W\"")
  end -- if

  dbot.notify.table.notifyLevel = value
  dbot.notify.save()

  return inv.tags.stop(invTagsNotify, endTag, DRL_RET_SUCCESS)
end -- dbot.notify.setLevel


function dbot.notify.getLevel()
  return dbot.notify.table.notifyLevel
end -- dbot.notify.getLevel


function dbot.notify.msg(level, msg)
  if (level == nil) or (level == "") then
    dbot.warn("dbot.notify.msg: missing level")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (dbot.notify.level[level] == nil) then
    dbot.warn("dbot.notify.msg: level \"" .. level .. "\" is not supported")
    return DRL_RET_UNSUPPORTED
  end -- if

  msg = msg or ""

  if (dbot.notify.level[level].enabled) then

    -- Suppress messages if we are writing a note
    if dbot.gmcp.isInitialized and (dbot.gmcp.getState() == dbot.stateNote) then
      return DRL_RET_BUSY
    end -- if

    ColourTell(dbot.notify.level[level].bg, dbot.notify.level[level].fg, dbot.notify.prefix)
    dbot.print("@W " .. msg .. "@w")
  end -- if

  return DRL_RET_SUCCESS
end -- dbot.notify.msg


function dbot.debug(msg)
  return dbot.notify.msg(notifyLevelDebug, msg)
end -- dbot.debug


function dbot.note(msg)
  return dbot.notify.msg(notifyLevelNote, msg)
end -- dbot.note


function dbot.info(msg)
  return dbot.notify.msg(notifyLevelInfo, msg)
end -- dbot.info


function dbot.warn(msg)
  return dbot.notify.msg(notifyLevelWarn, msg)
end -- dbot.warn


function dbot.error(msg)
  return dbot.notify.msg(notifyLevelError, msg)
end -- dbot.error


----------------------------------------------------------------------------------------------------
--
-- Module to access live data via the GMCP protocol
--
--  dbot.gmcp.init.atActive
--  dbot.gmcp.fini
--
--  dbot.gmcp.getState
--  dbot.gmcp.getStateString
--
--  dbot.gmcp.getClass
--  dbot.gmcp.getName
--  dbot.gmcp.getLevel
--  dbot.gmcp.getAlign
--  dbot.gmcp.getRoomId
--  dbot.gmcp.getTier
--
--  dbot.gmcp.isGood
--  dbot.gmcp.isNeutral
--  dbot.gmcp.isEvil
--
--  dbot.gmcp.statePreventsActions()
--  dbot.gmcp.stateIsActive
--
--  dbot.gmcp.getConfig
--
----------------------------------------------------------------------------------------------------

dbot.gmcp      = {}
dbot.gmcp.init = {}

dbot.gmcp.isInitialized = false  -- initialized when OnPluginBroadcast detects a GMCP message

dbot.stateLogin    = "1"
dbot.stateMOTD     = "2"
dbot.stateActive   = "3"
dbot.stateAFK      = "4"
dbot.stateNote     = "5"
dbot.stateBuilding = "6"
dbot.statePaged    = "7"
dbot.stateCombat   = "8"
dbot.stateSleeping = "9"
dbot.stateTBD      = "10" -- not defined in the docs
dbot.stateResting  = "11"
dbot.stateRunning  = "12"

dbot.stateNames = {}
dbot.stateNames[dbot.stateLogin]    = "Login"
dbot.stateNames[dbot.stateMOTD]     = "MOTD"
dbot.stateNames[dbot.stateActive]   = "Active"
dbot.stateNames[dbot.stateAFK]      = "AFK"
dbot.stateNames[dbot.stateNote]     = "Note"
dbot.stateNames[dbot.stateBuilding] = "Building"
dbot.stateNames[dbot.statePaged]    = "Paged"
dbot.stateNames[dbot.stateCombat]   = "Combat"
dbot.stateNames[dbot.stateSleeping] = "Sleeping"
dbot.stateNames[dbot.stateTBD]      = "Uninitialized"
dbot.stateNames[dbot.stateResting]  = "Resting"
dbot.stateNames[dbot.stateRunning]  = "Running"


function dbot.gmcp.init.atActive()
  local retval = DRL_RET_SUCCESS

  -- Placeholder: nothing to do for now...

  return retval
end -- dbot.gmcp.init.atActive


function dbot.gmcp.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  dbot.gmcp.isInitialized = false
  dbot.gmcp.currentState = {}

  -- Note: we don't use doSaveState yet because this module doesn't have state to save

  return retval
end -- dbot.gmcp.fini


function dbot.gmcp.getState()
  local charStatus

  if dbot.gmcp.isInitialized then
    charStatus = gmcp("char.status")
  else
    dbot.debug("dbot.gmcp.getState: GMCP is not initialized")
  end -- if

  if (charStatus == nil) then
    return dbot.stateTBD
  else
    -- dbot.showStateString(charStatus.state)
    return charStatus.state
  end -- if
end -- dbot.gmcp.getState


function dbot.gmcp.getStateString(state)
  return (dbot.stateNames[state] or "Unknown")
end -- dbot.gmcp.getStateString



function dbot.gmcp.getClass()
  local char
  local class, subclass = "", ""

  if dbot.gmcp.isInitialized then
    char = gmcp("char.base")
    if (char ~= nil) then
      class = char.class
      subclass = char.subclass
    end -- if
  else
    dbot.note("dbot.gmcp.getClass: GMCP is not initialized")
  end -- if

  return class, subclass
end -- dbot.gmcp.getClass


dbot.gmcp.charName = "unknown"
dbot.gmcp.charPretitle = "unknown"
function dbot.gmcp.getName()
  if dbot.gmcp.isInitialized then
    local char = gmcp("char.base")
    if (char ~= nil) then
      dbot.gmcp.charName = char.name
      dbot.gmcp.charPretitle = char.pretitle
    end -- if
  else
    dbot.debug("dbot.gmcp.getName: GMCP is not initialized")
  end -- if

  return dbot.gmcp.charName, dbot.gmcp.charPretitle
end -- dbot.gmcp.getName


function dbot.gmcp.getLevel()
  local charStatus
  local myLevel = 1

  if dbot.gmcp.isInitialized then
    charStatus = gmcp("char.status")
    if (charStatus ~= nil) then
      myLevel = (tonumber(charStatus.level) or 1) + (dbot.gmcp.getTier() * 10)
    end -- if
  else
    dbot.note("dbot.gmcp.getLevel: GMCP is not initialized")
  end -- if

  dbot.debug("dbot.gmcp.getLevel returns " .. myLevel)
  return myLevel

end -- dbot.gmcp.getLevel


function dbot.gmcp.getAlign()
  local charStatus
  local myAlign = 0

  if dbot.gmcp.isInitialized then
    charStatus = gmcp("char.status")
    if (charStatus ~= nil) then
      myAlign = tonumber(charStatus.align) or 0
    end -- if
  else
    dbot.note("dbot.gmcp.getAlign: GMCP is not initialized")
  end -- if

  return myAlign

end -- dbot.gmcp.getAlign


function dbot.gmcp.getRoomId()
  local roomInfo
  local roomId = 0

  if dbot.gmcp.isInitialized then
    roomInfo = gmcp("room.info")
    if (roomInfo ~= nil) and (roomInfo.num ~= nil) then
      roomId = roomInfo.num
    end -- if
  else
    dbot.note("dbot.gmcp.getRoomId: GMCP is not initialized")
  end -- if

  dbot.debug("dbot.gmcp.getRoomId returns " .. roomId)
  return roomId
end -- dbot.gmcp.getRoomId


function dbot.gmcp.getTier()
  local charBase
  local myTier = 0

  if dbot.gmcp.isInitialized then
    charBase = gmcp("char.base")
    if (charBase ~= nil) and (charBase.tier ~= nil) then
      myTier = tonumber(charBase.tier)
    end -- if
  else
    dbot.note("dbot.gmcp.getTier: GMCP is not initialized")
  end -- if

  dbot.debug("dbot.gmcp.getTier returns " .. myTier)
  return myTier

end -- dbot.gmcp.getTier


function dbot.gmcp.isGood()
  local align = dbot.gmcp.getAlign()

  if (align >= 875) then
    return true
  else
    return false
  end -- if

end -- dbot.gmcp.isGood


function dbot.gmcp.isNeutral()
  local align = dbot.gmcp.getAlign()

  if (align >= -874) and (align <= 874) then
    return true
  else
    return false
  end -- if

end -- dbot.gmcp.isNeutral


function dbot.gmcp.isEvil()
  local align = dbot.gmcp.getAlign()

  if (align <= -875) then
    return true
  else
    return false
  end -- if

end -- dbot.gmcp.isEvil


-- We can perform actions in the "active" and "combat" states.  Any other state has the potential
-- to prevent us from performing an action.
function dbot.gmcp.statePreventsActions()
  local state = dbot.gmcp.getState() or "Uninitialized"

  if (state == dbot.stateActive) or (state == dbot.stateCombat) then
    return false
  else
    return true
  end -- if
end -- dbot.gmcp.statePreventsActions


function dbot.gmcp.stateIsActive()
  return (dbot.gmcp.getState() == dbot.stateActive)
end -- dbot.gmcp.stateIsActive()


--[[ Available gmcpconfig modes
   Autoexit,
   Autoloot,
   Autorecall,
   Autosac,
   Autosave,
   Autotick,
   Bprompt,
   Catchtells,
   Color,
   Compact,
   Deaf,
   Echocommands,
   Invmon,
   Maprun,
   Noexp,
   Nomap,
   Noobjlevels,
   Nopagerepeat,
   Noprefix,
   Nopretitles,
   Noweather,
   Prompt,
   Promptflags,
   Quiet,
   Rawcolors,
   Savetells,
   Shortflags,
   Shortmap,
   Statmon,
   Strictpager,
   Strictsocials,
   Tickinfo,
   Xterm
--]]
dbot.gmcp.currentState = {}
-- Returns boolean representing "YES" or "NO" values from the mud for the specified mode
function dbot.gmcp.getConfig(configMode)
  if not configMode or configMode == "" then return nil, DRL_RET_INVALID_PARAM end
  local value = dbot.gmcp.currentState[configMode]
  if value == "YES" then return true, DRL_RET_SUCCESS end
  if value == "NO" then return false, DRL_RET_SUCCESS end
  Send_GMCP_Packet("config " .. configMode)
  return nil, DRL_RET_UNINITIALIZED
end -- dbot.gmcp.getConfig

----------------------------------------------------------------------------------------------------
-- Module to handle backing up the SQLite database
----------------------------------------------------------------------------------------------------
--
-- dinv backup [list | create | delete | restore] [name]
--
-- Backups are .db file copies stored in:
--   {pluginStatePath}/{charName}/backup/{name}.db
--
-- Functions:
--  dbot.backup.init.atActive()
--  dbot.backup.fini(doSaveState)
--
--  dbot.backup.getBackupDir()
--  dbot.backup.getBackups()
--
--  dbot.backup.preBuild()    -- automatic backup before dinv build confirm
--
--  dbot.backup.list(endTag)
--  dbot.backup.create(name, endTag)
--  dbot.backup.delete(name, endTag, isQuiet)
--  dbot.backup.restore(name, endTag)
--
----------------------------------------------------------------------------------------------------

dbot.backup      = {}
dbot.backup.init = {}


function dbot.backup.init.atActive()
  -- Create backup directory if it doesn't exist
  local backupDir = dbot.backup.getBackupDir()
  if not dbot.fileExists(backupDir) then
    dbot.shell('mkdir "' .. backupDir .. '"')
  end
  return DRL_RET_SUCCESS
end -- dbot.backup.init.atActive


function dbot.backup.fini(doSaveState)
  return DRL_RET_SUCCESS
end -- dbot.backup.fini


function dbot.backup.getBackupDir()
  return dinv_db.getDir() .. "backup\\", DRL_RET_SUCCESS
end -- dbot.backup.getBackupDir


-- Copy a file using Lua I/O. Returns true on success.
local function copyFile(src, dst)
  local srcFile = io.open(src, "rb")
  if not srcFile then return false end

  local data = srcFile:read("*a")
  srcFile:close()

  if not data then return false end

  local dstFile = io.open(dst, "wb")
  if not dstFile then return false end

  dstFile:write(data)
  dstFile:close()
  return true
end


-- Returns an array of backup info tables, sorted most recent first.
-- Each entry: { fileName = "name.db", baseName = "name", fullPath = "...", baseTime = timestamp }
function dbot.backup.getBackups()
  local backups = {}

  local backupDir = dbot.backup.getBackupDir()
  local dirQuery = string.gsub(backupDir, "\\", "/") .. "*.db"
  local dirTable = utils.readdir(dirQuery)
  if not dirTable then
    return backups, DRL_RET_SUCCESS
  end

  for fileName, fileEntry in pairs(dirTable) do
    if not fileEntry.directory then
      -- Parse name from "somename-timestamp.db"
      local baseName, baseTime = fileName:match("^(.*)-(%d+)%.db$")
      if baseName then
        table.insert(backups, {
          fileName = fileName,
          baseName = baseName,
          fullPath = backupDir .. fileName,
          baseTime = tonumber(baseTime) or 0,
        })
      end
    end
  end

  -- Sort most recent first
  table.sort(backups, function(a, b) return a.baseTime > b.baseTime end)

  return backups, DRL_RET_SUCCESS
end -- dbot.backup.getBackups


-- Automatic backup before dinv build confirm.
--
-- Proteles: disabled. The backup feature copies the SQLite DB file via Lua
-- `io` (copyFile), which the sandbox deliberately excludes, and the user-facing
-- `dinv backup` command is removed (see Resources/dinv/PROVENANCE.md). Skipping
-- here keeps `dinv build` from erroring on `io` once the DB has items.
function dbot.backup.preBuild()
  dbot.debug("dbot.backup.preBuild: backups disabled in Proteles; skipping")
  return DRL_RET_SUCCESS
end -- dbot.backup.preBuild


function dbot.backup.list(endTag)
  local backups, retval = dbot.backup.getBackups()

  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.backup.list: Failed to get backup list: " .. dbot.retval.getString(retval))
  elseif (#backups == 0) then
    dbot.info("No backups detected")
  else
    local suffix = (#backups ~= 1) and "s" or ""
    dbot.info("Detected " .. #backups .. " backup" .. suffix)
    for _, backup in ipairs(backups) do
      dbot.print("  @W(@c" .. os.date("%c", backup.baseTime) .. "@W) @G" .. backup.baseName)
    end
  end

  return inv.tags.stop(invTagsBackup, endTag, retval)
end -- dbot.backup.list


function dbot.backup.create(name, endTag)
  if (name == nil) or (name == "") then
    dbot.warn("dbot.backup.create: Missing name parameter")
    return inv.tags.stop(invTagsBackup, endTag, DRL_RET_INVALID_PARAM)
  end

  -- Remove any old backups with the same name
  dbot.backup.delete(name, nil, true)

  -- Flush any in-memory mutations to disk before we snapshot the file.
  -- Without this, a backup taken between two mutations could omit the
  -- newer one and "dinv backup restore" would silently roll back to a
  -- strictly older state than was visible when the backup ran.
  if type(inv.flush) == "function" then
    inv.flush()
  end

  -- Close the database to ensure the file is consistent
  dinv_db.close()

  local srcPath = dinv_db.getPath()
  local backupDir = dbot.backup.getBackupDir()
  local backupTime = dbot.getTime()
  local dstPath = backupDir .. name .. "-" .. backupTime .. ".db"

  local ok = copyFile(srcPath, dstPath)

  -- Reopen the database
  dinv_db.open()

  if not ok then
    dbot.warn("dbot.backup.create: Failed to copy database to backup")
    return inv.tags.stop(invTagsBackup, endTag, DRL_RET_INTERNAL_ERROR)
  end

  dbot.info("Created backup @W(@c" .. os.date("%c", backupTime) .. "@W) @G" .. name)
  return inv.tags.stop(invTagsBackup, endTag, DRL_RET_SUCCESS)
end -- dbot.backup.create


function dbot.backup.delete(name, endTag, isQuiet)
  if (name == nil) or (name == "") then
    dbot.warn("dbot.backup.delete: Missing name parameter")
    return inv.tags.stop(invTagsBackup, endTag, DRL_RET_INVALID_PARAM)
  end

  local backups, retval = dbot.backup.getBackups()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.backup.delete: Failed to get backup list: " .. dbot.retval.getString(retval))
    return inv.tags.stop(invTagsBackup, endTag, retval)
  end

  local numDeleted = 0
  for _, backup in ipairs(backups) do
    if (backup.baseName == name) then
      os.remove(backup.fullPath)
      if not isQuiet then
        dbot.info("Deleted backup @W(@c" .. os.date("%c", backup.baseTime) ..
                  "@W) @G" .. backup.baseName)
      end
      numDeleted = numDeleted + 1
    end
  end

  if (numDeleted == 0) and not isQuiet then
    dbot.info("No backups matching name \"@G" .. name .. "@w\" were found")
  end

  return inv.tags.stop(invTagsBackup, endTag, DRL_RET_SUCCESS)
end -- dbot.backup.delete


dbot.backup.restorePkg = nil
function dbot.backup.restore(name, endTag)
  if (name == nil) or (name == "") then
    dbot.warn("dbot.backup.restore: Missing name parameter")
    return inv.tags.stop(invTagsBackup, endTag, DRL_RET_INVALID_PARAM)
  end

  if (dbot.backup.restorePkg ~= nil) then
    dbot.info("Skipping backup restore request: another restore is in progress")
    return inv.tags.stop(invTagsBackup, endTag, DRL_RET_BUSY)
  end

  dbot.backup.restorePkg        = {}
  dbot.backup.restorePkg.name   = name
  dbot.backup.restorePkg.endTag = endTag

  inv.runtime.start(dbot.backup.restoreCR, dbot.backup, "restorePkg")

  return DRL_RET_SUCCESS
end -- dbot.backup.restore


function dbot.backup.restoreCR()
  if (dbot.backup.restorePkg == nil) then
    dbot.warn("dbot.backup.restoreCR: restore package is nil")
    return inv.tags.stop(invTagsBackup, nil, DRL_RET_INTERNAL_ERROR)
  end

  local name   = dbot.backup.restorePkg.name
  local endTag = dbot.backup.restorePkg.endTag
  local retval = DRL_RET_SUCCESS

  local backups
  backups, retval = dbot.backup.getBackups()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.backup.restore: Failed to get backup list: " .. dbot.retval.getString(retval))
    dbot.backup.restorePkg = nil
    return inv.tags.stop(invTagsBackup, endTag, retval)
  end

  -- Find the matching backup
  local backupPath = nil
  local backupTime = 0
  for _, backup in ipairs(backups) do
    if (backup.baseName == name) then
      backupPath = backup.fullPath
      backupTime = backup.baseTime
      break
    end
  end

  if not backupPath then
    dbot.warn("Failed to restore backup \"@G" .. name .. "@W\": could not find backup")
    dbot.backup.restorePkg = nil
    return inv.tags.stop(invTagsBackup, endTag, DRL_RET_MISSING_ENTRY)
  end

  dbot.info("Restoring backup @W(@c" .. os.date("%c", backupTime) .. "@W) @G" .. name)

  -- Close the database, copy backup over it, then reload
  dinv_db.close()

  local dstPath = dinv_db.getPath()
  local ok = copyFile(backupPath, dstPath)

  if not ok then
    dbot.warn("dbot.backup.restore: Failed to copy backup over database")
    dinv_db.open()
    dbot.backup.restorePkg = nil
    return inv.tags.stop(invTagsBackup, endTag, DRL_RET_INTERNAL_ERROR)
  end

  -- Reload the plugin to pick up the restored state (without saving current state)
  retval = inv.reload(drlDoNotSaveState)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.backup.restore: Failed to reload plugin: " .. dbot.retval.getString(retval))
  end

  dbot.backup.restorePkg = nil
  return inv.tags.stop(invTagsBackup, endTag, retval)
end -- dbot.backup.restoreCR


----------------------------------------------------------------------------------------------------
--
-- Module to disable and enable empty lines
--
-- Many of the commands this plugin runs in the background generate empty lines of output.  We don't
-- want the user to suddenly see empty lines showing up without warning so we provide a way to
-- suppress empty lines when desired.
--
--
-- dbot.emptyLine.init.atInstall()
-- dbot.emptyLine.fini(doSaveState)
--
-- dbot.emptyLine.disable()
-- dbot.emptyLine.enable()
--
----------------------------------------------------------------------------------------------------

dbot.emptyLine         = {}
dbot.emptyLine.init    = {}
dbot.emptyLine.trigger = {}

dbot.emptyLine.trigger.suppressEmptyName = "drlDbotEmptyLineTrigger"
dbot.emptyLine.numEnables = 1 -- empty lines are enabled by default


function dbot.emptyLine.init.atInstall()
  local retval = DRL_RET_SUCCESS

  -- Suppress empty lines (white space only)
  check (AddTriggerEx(dbot.emptyLine.trigger.suppressEmptyName,
                      "^[ ]*$",
                      "",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(dbot.emptyLine.trigger.suppressEmptyName, false)) -- default to off

  return retval
end -- dbot.emptyLine.init.atInstall


function dbot.emptyLine.fini(doSaveState)
  dbot.deleteTrigger(dbot.emptyLine.trigger.suppressEmptyName)

  dbot.emptyLine.numEnables = 1 -- empty lines are enabled by default

  -- NOTE: if we ever add persistent data to this module we should use the doSaveState param to determine
  -- if we need to save it

  return DRL_RET_SUCCESS
end -- dbot.emptyLine.fini


function dbot.emptyLine.disable()
  local retval = DRL_RET_SUCCESS

  dbot.emptyLine.numEnables = dbot.emptyLine.numEnables - 1
  if (dbot.emptyLine.numEnables == 0) then
    dbot.debug("dbot.emptyLine.disable: suppressing empty lines")
    EnableTrigger(dbot.emptyLine.trigger.suppressEmptyName, true)
  end -- if

  return retval
end -- dbot.emptyLine.disable


function dbot.emptyLine.enable()
  local retval = DRL_RET_SUCCESS

  dbot.emptyLine.numEnables = dbot.emptyLine.numEnables + 1
  if (dbot.emptyLine.numEnables == 1) then
    dbot.debug("dbot.emptyLine.enable: allowing empty lines")
    EnableTrigger(dbot.emptyLine.trigger.suppressEmptyName, false)
  end -- if

  return retval
end -- dbot.emptyLine.enable


----------------------------------------------------------------------------------------------------
--
-- Module to disable and enable the prompt
--
-- This uses low-level telnet 102 commands so that we can change the prompt status even if the
-- character is AFK.
--
-- dbot.prompt.init.atActive()
-- dbot.prompt.fini(doSaveState)
--
-- dbot.prompt.disable()
-- dbot.prompt.enable()
-- dbot.prompt.hide() -- disables both the prompt and empty lines
-- dbot.prompt.show() -- enables both the prompt and empty lines
-- dbot.prompt.getStatusCR()
--
-- dbot.prompt.trigger.onToggle(msg)
--
----------------------------------------------------------------------------------------------------

dbot.prompt         = {}
dbot.prompt.init    = {}
dbot.prompt.trigger = {}

dbot.prompt.trigger.onToggleName      = "drlDbotPromptTriggerOnToggle"

dbot.prompt.isEnabled = nil -- unknown until observed; never interpreted as off


function dbot.prompt.init.atActive()
  local retval = DRL_RET_SUCCESS

  check (AddTriggerEx(dbot.prompt.trigger.onToggleName,
                      "^(You will no longer see prompts|You will now see prompts).*$",
                      "dbot.prompt.trigger.onToggle(\"%1\")",
                      drlTriggerFlagsBaseline,
                      custom_colour.NoChange, 0, "", "", sendto.script, 0))
  check (EnableTrigger(dbot.prompt.trigger.onToggleName, false)) -- default to off

  -- We will fill this in when we call dbot.prompt.isEnabledCR
  dbot.prompt.statusEnables = 1

  -- The *.init.atActive code runs in a co-routine so we don't need to explicitly kick off another CR here
  dbot.prompt.getStatusCR()

  return retval
end -- dbot.prompt.init.atActive


function dbot.prompt.fini(doSaveState)
  dbot.deleteTrigger(dbot.prompt.trigger.onToggleName)

  dbot.prompt.isEnabled = nil

  -- NOTE: if we ever add persistent data to this module we should use the doSaveState param to determine
  -- if we need to save it

  return DRL_RET_SUCCESS
end -- dbot.prompt.fini


function dbot.prompt.disable()
  -- Presentation never changes server prompt configuration.
end -- dbot.prompt.disable

function dbot.prompt.enable()
  -- Presentation never changes server prompt configuration.
end -- dbot.prompt.enable

-- Disable the prompt and suppress empty lines
function dbot.prompt.hide()
  -- Presentation never changes server prompt configuration.
end -- dbot.prompt.hide

function dbot.prompt.show()
  -- Presentation never changes server prompt configuration.
end -- dbot.prompt.show

function dbot.prompt.getStatusCR()
  local value, retval = dbot.gmcp.getConfig("prompt")
  dbot.prompt.isEnabled = value
  EnableTrigger(dbot.prompt.trigger.onToggleName, true)
  return retval
end -- dbot.prompt.getStatusCR

function dbot.prompt.trigger.onToggle(msg)

  if (msg == "You will no longer see prompts") then
    dbot.debug("dbot.prompt.trigger.onToggle: user manually turned the prompt off")
    dbot.prompt.isEnabled = false
    inv.config.table.isPromptEnabled = false

  elseif (msg == "You will now see prompts") then
    dbot.debug("dbot.prompt.trigger.onToggle: user manually turned the prompt on")
    dbot.prompt.isEnabled = true
    inv.config.table.isPromptEnabled = true

  else
    dbot.error("dbot.prompt.trigger.onToggle: triggered on unsupported message \"" .. (msg or "nil") .. "\"")
  end -- if

  if (dbot.init.initializedActive) then
    inv.config.save()
  end -- if

end -- dbot.prompt.trigger.onToggle


----------------------------------------------------------------------------------------------------
--
-- Module to check the status of invmon
--
-- dbot.invmon.init.atInstall()
-- dbot.invmon.init.atActive()
-- dbot.invmon.fini(doSaveState)
--
-- dbot.invmon.getStatusCR()
--
-- dbot.invmon.trigger.onToggle(msg)
--
----------------------------------------------------------------------------------------------------

dbot.invmon         = {}
dbot.invmon.init    = {}
dbot.invmon.trigger = {}

dbot.invmon.isEnabled = true -- by default, assume the invmon is enabled

dbot.invmon.trigger.onToggleName      = "drlDbotInvmonTriggerOnToggle"


function dbot.invmon.init.atInstall()
  local retval = DRL_RET_SUCCESS

  check (AddTriggerEx(dbot.invmon.trigger.onToggleName,
                      "^(" ..
                         "You will no longer see inventory update tags." ..
                         "|You will now see inventory update tags."      ..
                      ").*$",
                      "dbot.invmon.trigger.onToggle(\"%1\")",
                      drlTriggerFlagsBaseline,
                      custom_colour.NoChange, 0, "", "", sendto.script, 0))
  check (EnableTrigger(dbot.invmon.trigger.onToggleName, false)) -- default to off

  return retval
end -- dbot.invmon.init.atInstall


function dbot.invmon.init.atActive()
  local retval = DRL_RET_SUCCESS

  -- We will fill this in when we call dbot.invmon.isEnabledCR.  We need to manually toggle "invmon"
  -- two times and see what the output is in order to determine what the actual status of the invmon
  -- is.  We can't do that synchronously here so we kick off a co-routine to get that info.
  dbot.invmon.statusEnables = 0

  -- The *.init.atActive code runs in a co-routine so we don't need to explicitly kick off another CR here
  dbot.invmon.getStatusCR()

  return retval
end -- dbot.invmon.init.atActive


function dbot.invmon.fini(doSaveState)

  dbot.deleteTrigger(dbot.invmon.trigger.onToggleName)

  dbot.invmon.isEnabled = true

  -- NOTE: if we ever add persistent data to this module we should use the doSaveState param to determine
  -- if we need to save it

  return DRL_RET_SUCCESS
end -- dbot.invmon.fini


function dbot.invmon.getStatusCR()
  local value, retval = dbot.gmcp.getConfig("invmon")
  dbot.invmon.isEnabled = value
  EnableTrigger(dbot.invmon.trigger.onToggleName, true)
  return retval
end -- dbot.invmon.getStatusCR

function dbot.invmon.trigger.onToggle(msg)
  if (msg == "You will no longer see inventory update tags.") then
    dbot.debug("dbot.invmon.trigger.onToggle: user manually turned invmon off")
    dbot.invmon.statusEnables = dbot.invmon.statusEnables - 1
    dbot.warn("You just disabled invmon!")
    dbot.warn("The dinv plugin requires invmon.  Please type \"invmon\" to enable it again.")
  elseif (msg == "You will now see inventory update tags.") then
    dbot.debug("dbot.invmon.trigger.onToggle: user manually turned invmon on")
    dbot.invmon.statusEnables = dbot.invmon.statusEnables + 1
  else
    dbot.error("dbot.invmon.trigger.onToggle: triggered on unsupported message \"" .. (msg or "nil") .. "\"")
  end -- if
end -- dbot.invmon.trigger.onToggle


----------------------------------------------------------------------------------------------------
-- Invmon helper code and definitions
----------------------------------------------------------------------------------------------------

invmon = {}

invmonActionRemoved             = 1
invmonActionWorn                = 2
invmonActionRemovedFromInv      = 3
invmonActionAddedToInv          = 4
invmonActionTakenOutOfContainer = 5
invmonActionPutIntoContainer    = 6
invmonActionConsumed            = 7
invmonActionPutIntoVault        = 9
invmonActionRemovedFromVault    = 10
invmonActionPutIntoKeyring      = 11
invmonActionGetFromKeyring      = 12

invmon.action = {}
invmon.action[invmonActionRemoved]             = "Removed"
invmon.action[invmonActionWorn]                = "Worn"
invmon.action[invmonActionRemovedFromInv]      = "Removed from inventory"
invmon.action[invmonActionAddedToInv]          = "Added to inventory"
invmon.action[invmonActionTakenOutOfContainer] = "Taken out of container"
invmon.action[invmonActionPutIntoContainer]    = "Put into container"
invmon.action[invmonActionConsumed]            = "Consumed"
invmon.action[invmonActionPutIntoVault]        = "Put into vault"
invmon.action[invmonActionRemovedFromVault]    = "Removed from vault"
invmon.action[invmonActionPutIntoKeyring]      = "Put into keyring"
invmon.action[invmonActionGetFromKeyring]      = "Get from keyring"

invmonTypeNone           = 0
invmonTypeLight          = 1
invmonTypeScroll         = 2
invmonTypeWand           = 3
invmonTypeStaff          = 4
invmonTypeWeapon         = 5
invmonTypeTreasure       = 6
invmonTypeArmor          = 7
invmonTypePotion         = 8
invmonTypeFurniture      = 9
invmonTypeTrash          = 10
invmonTypeContainer      = 11
invmonTypeDrinkContainer = 12
invmonTypeKey            = 13
invmonTypeFood           = 14
invmonTypeBoat           = 15
invmonTypeMobCorpse      = 16
invmonTypePlayerCorpse   = 17
invmonTypeFountain       = 18
invmonTypePill           = 19
invmonTypePortal         = 20
invmonTypeBeacon         = 21
invmonTypeGiftCard       = 22
invmonTypeUnused         = 23
invmonTypeRawMaterial    = 24
invmonTypeCampfire       = 25
invmonTypeForge          = 26
invmonTypeRunestone      = 27

invmon.typeStr = {}
invmon.typeStr[invmonTypeNone]           = "None"
invmon.typeStr[invmonTypeLight]          = "Light"
invmon.typeStr[invmonTypeScroll]         = "Scroll"
invmon.typeStr[invmonTypeWand]           = "Wand"
invmon.typeStr[invmonTypeStaff]          = "Staff"
invmon.typeStr[invmonTypeWeapon]         = "Weapon"
invmon.typeStr[invmonTypeTreasure]       = "Treasure"
invmon.typeStr[invmonTypeArmor]          = "Armor"
invmon.typeStr[invmonTypePotion]         = "Potion"
invmon.typeStr[invmonTypeFurniture]      = "Furniture"
invmon.typeStr[invmonTypeTrash]          = "Trash"
invmon.typeStr[invmonTypeContainer]      = "Container"
invmon.typeStr[invmonTypeDrinkContainer] = "Drink"
invmon.typeStr[invmonTypeKey]            = "Key"
invmon.typeStr[invmonTypeFood]           = "Food"
invmon.typeStr[invmonTypeBoat]           = "Boat"
invmon.typeStr[invmonTypeMobCorpse]      = "Mobcorpse"
invmon.typeStr[invmonTypePlayerCorpse]   = "Playercorpse"
invmon.typeStr[invmonTypeFountain]       = "Fountain"
invmon.typeStr[invmonTypePill]           = "Pill"
invmon.typeStr[invmonTypePortal]         = "Portal"
invmon.typeStr[invmonTypeBeacon]         = "Beacon"
invmon.typeStr[invmonTypeGiftCard]       = "Giftcard"
invmon.typeStr[invmonTypeUnused]         = "Unused"
invmon.typeStr[invmonTypeRawMaterial]    = "Raw material"
invmon.typeStr[invmonTypeCampfire]       = "Campfire"
invmon.typeStr[invmonTypeForge]          = "Forge"
invmon.typeStr[invmonTypeRunestone]      = "Runestone"


-- Returns true if an item type is one the frequent item cache may hold.  These
-- are the only types for which cloning a template by name is safe: every
-- instance of the same name is effectively interchangeable (e.g. bulk-bought
-- potions).  Uniquely-enchanted gear that shares a base name -- several
-- differently-enchanted "Aardwolf Bracers of Iron Grip", say -- must NOT be
-- cloned, so it is excluded here.  Both the items-table template fallback in
-- invitem handling and inv.cache.add gate on this.
function invmon.isFrequentCacheType(typeName)
  return (typeName == invmon.typeStr[invmonTypePotion]) or
         (typeName == invmon.typeStr[invmonTypePill])   or
         (typeName == invmon.typeStr[invmonTypeFood])   or
         (typeName == invmon.typeStr[invmonTypeWand])   or
         (typeName == invmon.typeStr[invmonTypeStaff])  or
         (typeName == invmon.typeStr[invmonTypeScroll])
end


----------------------------------------------------------------------------------------------------
--
-- dbot.ability: Module to check if a character has access to a specific skill or spell
--
-- Note: Previous releases used a complicated caching scheme based on the output of the showskill
--       command.  However, aard has now implemented a way to provide a class list via gmcp and
--       that is what we now do.
--
-- dbot.ability.isAvailable
--
----------------------------------------------------------------------------------------------------

dbot.ability = {}

-- Aard's gmcp implementation numbers each class from 0-6.  Use the text name here for easier debugging.
dbot.ability.classes = {}
dbot.ability.classes["0"] = "mag"
dbot.ability.classes["1"] = "cle"
dbot.ability.classes["2"] = "thi"
dbot.ability.classes["3"] = "war"
dbot.ability.classes["4"] = "ran"
dbot.ability.classes["5"] = "pal"
dbot.ability.classes["6"] = "psi"

dbot.ability.table = {}
dbot.ability.table["dual wield"] = { mag = 201, cle = 201, thi =  29, war =  32, ran =  25, pal =  35, psi = 201 }
dbot.ability.table["axe"]        = { mag = nil, cle = nil, thi = nil, war =   2, ran =   1, pal = nil, psi = nil }
dbot.ability.table["bow"]        = { mag = nil, cle = nil, thi = nil, war = nil, ran =   1, pal = nil, psi = nil }
dbot.ability.table["dagger"]     = { mag =   1, cle = nil, thi =   1, war =   4, ran =   5, pal = nil, psi =  10 }
dbot.ability.table["flail"]      = { mag = nil, cle =   5, thi = nil, war =   7, ran = nil, pal =   1, psi =  11 }
dbot.ability.table["hammer"]     = { mag = nil, cle = nil, thi = nil, war =   1, ran = nil, pal = nil, psi = nil }
dbot.ability.table["mace"]       = { mag = nil, cle =   1, thi =  10, war =   5, ran = nil, pal =   6, psi =   5 }
dbot.ability.table["polearm"]    = { mag = nil, cle = nil, thi = nil, war =   7, ran =  13, pal =  10, psi = nil }
dbot.ability.table["spear"]      = { mag =   1, cle = nil, thi = nil, war =  10, ran =  11, pal =  11, psi = nil }
dbot.ability.table["sword"]      = { mag = nil, cle = nil, thi = nil, war =   1, ran =   2, pal =   2, psi = nil }
dbot.ability.table["whip"]       = { mag =   5, cle =  10, thi =   3, war =   9, ran =  18, pal =   1, psi =   1 }
dbot.ability.table["exotic"]     = { mag =   1, cle =   1, thi =   1, war =   1, ran =   1, pal =   1, psi =   1 }


function dbot.ability.isAvailable(ability, level)
  local retval = DRL_RET_SUCCESS
  local abilityIsAvailable = false

  if (ability == nil) or (ability == "") then
    dbot.warn("dbot.ability.isAvailable: missing ability parameter")
    return abilityIsAvailable, DRL_RET_INVALID_PARAM
  end -- if

  if (dbot.ability.table[ability] == nil) then
    dbot.warn("dbot.ability.isAvailable: request to check unsupported ability \"" .. ability .. "\"")
    return abilityIsAvailable, DRL_RET_UNSUPPORTED
  end -- if

  if (level == nil) or (tonumber(level) == nil) then
    dbot.warn("dbot.ability.isAvailable: level parameter is not a number")
    return abilityIsAvailable, DRL_RET_INVALID_PARAM
  end -- if

  local reqLevel = tonumber(level)

  local base = gmcp("char.base")
  if (base == nil) or (base.classes == nil) or (base.classes == "") then
    dbot.error("dbot.ability.isAvailable: Failed to retrieve class information via gmcp")
    return abilityIsAvailable, DRL_RET_INTERNAL_ERROR
  end -- if
  local classList = base.classes

  dbot.debug("Checking for \"" .. ability .. "\" @@ level " .. level .. ", classes = \"" .. base.classes .. "\"")

  -- For each class in the char's mort list, check if they have access to the skill
  for classNum in classList:gmatch("%d") do
    local className = dbot.ability.classes[classNum]
    if (className == nil) then
      dbot.error("dbot.ability.isAvailable: Detected invalid class number \"" .. (classNum or "nil") .. "\"")
      return abilityIsAvailable, DRL_RET_INTERNAL_ERROR
    end -- if

    local classLevel = dbot.ability.table[ability][className]
    if (classLevel ~= nil) and (reqLevel >= classLevel) then
      dbot.debug("\"" .. ability .. "\" is available from class \"" .. className .. "\" @@ level " .. classLevel)
      abilityIsAvailable = true
      break
    end -- if
  end -- for

  return abilityIsAvailable, retval

end -- dbot.ability.isAvailable


----------------------------------------------------------------------------------------------------
--
-- Module to track wishes
--
-- dbot.wish.init.atActive()
-- dbot.wish.fini(doSaveState)
--
-- dbot.wish.save()
-- dbot.wish.load()
-- dbot.wish.reset()
--
-- dbot.wish.get()
-- dbot.wish.getCR()
-- dbot.wish.has(wishName)
--
-- dbot.wish.trigger.fn()
-- dbot.wish.setupFn() -- enable the trigger during a safe execute call
--
----------------------------------------------------------------------------------------------------

dbot.wish         = {}
dbot.wish.table   = {}
dbot.wish.init    = {}
dbot.wish.trigger = {}
dbot.wish.timer   = {}

dbot.wish.trigger.startName = "drlDbotWishTriggerStart"
dbot.wish.trigger.itemName  = "drlDbotWishTriggerItem"

dbot.wish.timer.name = "drlDbotWishTimer"
dbot.wish.timer.min = 1
dbot.wish.timer.sec = 0


function dbot.wish.init.atActive()
  local retval = DRL_RET_SUCCESS

  -- Pull in what we already know
  retval = dbot.wish.load()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.wish.init.atActive: Failed to load wish data: " .. dbot.retval.getString(retval))
  end -- if

  -- Trigger on the output of "wish list" and watch for a fence message to tell us we are done
  check (AddTriggerEx(dbot.wish.trigger.itemName,
                      "^(\\s*Base Cost\\s+Adjustment\\s+Your Cost\\s+Keyword|" ..
                      "\\s*[- ]{10,}|\\s*\\*?.+\\s+[0-9]+\\s+[0-9]+\\s+(?:--|[0-9]+)\\s+[^ ]+\\s*|" ..
                      "Your total adjustment cost is: [0-9]+|Your quest points on hand are: [0-9]+|" ..
                      "Refer to 'help wish' for a description of each wish\\.)$",
                      "dbot.wish.trigger.fn(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11,
                      0, "", "", sendto.script, 0))

  check (EnableTrigger(dbot.wish.trigger.itemName, false)) -- default to off

  dbot.wish.timer.name = inv.runtime.after(1, dbot.wish.get)

  return retval
end -- dbot.wish.init.atActive


function dbot.wish.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  dbot.deleteTrigger(dbot.wish.trigger.itemName)
  dbot.deleteTrigger(dbot.wish.trigger.startName)

  -- Whack the timer just in case it is running
  dbot.deleteTimer(dbot.wish.timer.name)

  if (doSaveState) then
    -- Save our current wish data
    retval = dbot.wish.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("dbot.wish.fini: Failed to save wish data: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  return retval
end -- dbot.wish.fini


function dbot.wish.save()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  if not dbot.wish.table then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM config WHERE key LIKE 'wish.%'")

    for wishName, _ in pairs(dbot.wish.table) do
      local query = string.format("INSERT INTO config (key, value) VALUES (%s, 'true')",
                                  dinv_db.fixsql("wish." .. wishName))
      db:exec(query)
      if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
        dbot.warn("dbot.wish.save: Failed to save wish " .. wishName)
        return DRL_RET_INTERNAL_ERROR
      end
    end

    return DRL_RET_SUCCESS
  end)
end -- dbot.wish.save


function dbot.wish.load()
  local db = dinv_db.handle
  if not db then
    dbot.wish.reset()
    return DRL_RET_SUCCESS
  end

  -- Check if any wish rows exist
  local count = 0
  for row in db:nrows("SELECT COUNT(*) as cnt FROM config WHERE key LIKE 'wish.%'") do
    count = row.cnt
  end

  if count == 0 then
    dbot.wish.table = {}
    return DRL_RET_SUCCESS
  end

  dbot.wish.table = {}
  for row in db:nrows("SELECT key, value FROM config WHERE key LIKE 'wish.%'") do
    local wishName = row.key:sub(6)  -- strip "wish." prefix
    dbot.wish.table[wishName] = true
  end

  return DRL_RET_SUCCESS
end -- dbot.wish.load


function dbot.wish.reset()
  dbot.wish.table = {}

  local retval = dbot.wish.save()
  if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("dbot.wish.reset: Failed to save wish persistent data: " .. dbot.retval.getString(retval))
  end -- if

  return retval
end -- dbot.wish.reset


dbot.wish.inProgress = false
function dbot.wish.get()
  if not inv.runtime.enabled then return DRL_RET_HALTED end
  if (dbot.wish.inProgress == true) then
    dbot.debug("Wish request already in progress")
    return DRL_RET_BUSY
  end -- if

  dbot.wish.inProgress = true

  inv.runtime.start(dbot.wish.getCR, nil, nil, function() dbot.wish.inProgress = false end)

  return DRL_RET_SUCCESS
end -- dbot.wish.get


function dbot.wish.getCR()
  local retval = DRL_RET_SUCCESS
  local charState = dbot.gmcp.getState()
  local pageLines
  if inv.commands.backgroundReady() then pageLines, retval = dbot.pagesize.get() end

  -- If we are not in the active state (i.e., AFK, sleeping, running, writing a note, etc.) then
  -- we can't get the list of wishes and we need to try again later
  if not inv.commands.backgroundReady() then
    dbot.debug("Skipping request to get list of active wishes: you are in the state \"" ..
              dbot.gmcp.getStateString(charState) .. "\"")
    retval = DRL_RET_NOT_ACTIVE

  -- We are in the active state and can execute commands on the server side
  elseif (pageLines ~= nil) and retval == DRL_RET_SUCCESS then

    -- Execute the "wish list" command
    -- TODO: Doh!  I just found the pagesize option in the "help telnet" helpfile.  This is in
    --       the telnet 102 interface and it lets you enable or disable paging easily.  It even
    --       remembers pagesize for you.  We may want to switch to that at some point.
    local commandArray = {}

    if (pageLines == 0) then
      table.insert(commandArray, "wish list")
    else
      table.insert(commandArray, "pagesize 0")
      table.insert(commandArray, "wish list")
      table.insert(commandArray, "pagesize " .. pageLines)
    end -- if

    local resultData = dbot.callback.new()
    retval = dbot.execute.safe.commands(commandArray, dbot.wish.setupFn, nil,
                                        dbot.wish.resultFn, resultData,
      {conflicts = {wish = true, pagesize = true},
       captureComplete = function() return dbot.wish.captureCompleted end})
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("dbot.wish.getCR: Failed to safely execute \"@Gwish list@W\": " ..
                dbot.retval.getString(retval))
    else
      -- Wait for confirmation that the "wish list" safe execution command completed
      retval = dbot.callback.wait(resultData, 30)
      if (retval ~= DRL_RET_SUCCESS) then
        inv.commands.probeNote(retval, "Skipping \"wish list\" request: " .. dbot.retval.getString(retval))
      end -- if

      if retval == DRL_RET_SUCCESS and not dbot.wish.captureCompleted then
        retval = DRL_RET_TIMEOUT
      end

    end -- if

  else
    if retval == DRL_RET_SUCCESS then retval = DRL_RET_TIMEOUT end
  end -- if

  dbot.wish.inProgress = false

  -- If we weren't able to snag the list of wishes, try again later
  if (retval ~= DRL_RET_SUCCESS) then
    inv.runtime.removeTimer(dbot.wish.timer.name)
    dbot.wish.timer.name = inv.runtime.after(dbot.wish.timer.min * 60 + dbot.wish.timer.sec,
      dbot.wish.get)
  else
    -- We found the wishes.  Save them!
    dbot.debug("dbot.wish.getCR: detected purchased wishes!")
    dbot.wish.save()
  end -- if

  return retval
end -- dbot.wish.getCR


function dbot.wish.trigger.fn(line)
  if line:match("^%s*Base Cost%s+Adjustment%s+Your Cost%s+Keyword$") then
    dbot.wish.sawHeader = true
  elseif line == "Refer to 'help wish' for a description of each wish." then
    dbot.wish.captureCompleted = dbot.wish.sawHeader == true
    EnableTrigger(dbot.wish.trigger.itemName, false)
  elseif dbot.wish.sawHeader and dbot.wish.pending then
    local wishName = line:match("%-%- ([^ -]+)%s*$")
    if wishName then dbot.wish.pending[wishName] = true end
  end
end -- dbot.wish.trigger.fn


function dbot.wish.has(wishName)
  if (wishName == nil) or (wishName == "") or
     (dbot.wish.table == nil) or (dbot.wish.table[wishName] == nil) then
    return false
  else
    return true
  end -- if
end -- dbot.wish.has


function dbot.wish.setupFn()
  dbot.wish.pending = {}
  dbot.wish.captureCompleted, dbot.wish.sawHeader = false, false
  EnableTrigger(dbot.wish.trigger.itemName, true)
  dbot.pagesize.hide()
end -- dbot.wish.setupFn

function dbot.wish.resultFn(resultData, retval)
  if not inv.commands.ownsResponse(resultData) then return dbot.callback.default(resultData, retval) end
  EnableTrigger(dbot.wish.trigger.itemName, false)
  dbot.pagesize.show()
  if retval == DRL_RET_SUCCESS then
    if dbot.wish.captureCompleted and dbot.wish.pending then
      dbot.wish.table = dbot.wish.pending
    else retval = DRL_RET_TIMEOUT end
  end
  dbot.wish.pending = nil
  dbot.callback.default(resultData, retval)
end -- dbot.wish.resultFn

----------------------------------------------------------------------------------------------------
--
-- Module to get and set the mud's output page size
--
-- Page size refers to the number of lines of output that are displayed in one command before the mud
-- gives the user a page prompt
--
-- dbot.pagesize.init.atActive()
-- dbot.pagesize.fini(doSaveState)
--
-- dbot.pagesize.get() -- Note: this must be called from within a co-routine
--
-- dbot.pagesize.hide()
-- dbot.pagesize.show()
--
-- dbot.pagesize.trigger.fn()                 -- catch the # lines output
-- dbot.pagesize.setupFn(setupData)           -- enable the trigger
-- dbot.pagesize.resultFn(resultData, retval) -- disable the trigger
--
-- Output syntax:
--   You currently display 55 lines per page.
--   Use 'pagesize <lines>' to change, or 'pagesize 0' to disable paging.
----------------------------------------------------------------------------------------------------

dbot.pagesize         = {}
dbot.pagesize.init    = {}
dbot.pagesize.trigger = {}
dbot.pagesize.lines   = nil

dbot.pagesize.trigger.getName      = "drlDbotPageSizeTrigger"
dbot.pagesize.trigger.suppressName = "drlDbotPageSizeSuppressTrigger"


function dbot.pagesize.init.atActive()
  local retval = DRL_RET_SUCCESS

  -- Trigger on the output of "pagesize"
  check (AddTriggerEx(dbot.pagesize.trigger.getName,
                      "^("                                              ..
                        "|You currently display [0-9]+ lines per page." ..
                        "|You do not page long messages."               ..
                        "|Use .* to disable paging."                    ..
                      ")$",
                      "dbot.pagesize.trigger.fn(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(dbot.pagesize.trigger.getName, false)) -- default to off

  check (AddTriggerEx(dbot.pagesize.trigger.suppressName,
                      "^(Paging disabled.|Page size set to .* lines.)$",
                      "",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))
  check (EnableTrigger(dbot.pagesize.trigger.suppressName, false)) -- default to off

  return retval
end -- dbot.pagesize.init.atActive


function dbot.pagesize.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  dbot.deleteTrigger(dbot.pagesize.trigger.getName)
  dbot.deleteTrigger(dbot.pagesize.trigger.suppressName)

  -- We don't currently save the state of the page size, but we could add that here if we wanted to

  return retval
end -- dbot.pagesize.fini


function dbot.pagesize.get()
  local retval = DRL_RET_SUCCESS
  local commandArray = { "pagesize" }

  retval = dbot.execute.safe.blocking({"pagesize"}, dbot.pagesize.setupFn, nil, dbot.pagesize.resultFn, 10,
    {conflicts = {pagesize = true}})
  if (retval ~= DRL_RET_SUCCESS) then
    inv.commands.probeNote(retval, "Skipped getting \"@Gpagesize@W\": " ..
              dbot.retval.getString(retval))
  else
    dbot.debug("Read current page size: " .. (dbot.pagesize.lines or "nil"))
  end -- if

  if retval ~= DRL_RET_SUCCESS then return nil, retval end
  return dbot.pagesize.lines, retval
end -- dbot.pagesize.get


function dbot.pagesize.hide()
  EnableTrigger(dbot.pagesize.trigger.suppressName, true)
end -- dbot.pagesize.hide


function dbot.pagesize.show()
  EnableTrigger(dbot.pagesize.trigger.suppressName, false)
end -- dbot.pagesize.show


function dbot.pagesize.trigger.fn(msg)

  local _, _, lines = string.find(msg, "You currently display ([%d]+) lines per page")
  lines = tonumber(lines or "")

  if (msg == "You do not page long messages.") then
    dbot.pagesize.pending = 0

  elseif (lines ~= nil) then
    dbot.pagesize.pending = lines

  end -- if
end -- dbot.pagesize.trigger.fn


function dbot.pagesize.setupFn(setupData)
  dbot.pagesize.pending = nil
  EnableTrigger(dbot.pagesize.trigger.getName, true)
end -- dbot.pagesize.setupFn


function dbot.pagesize.resultFn(resultData, retval)
  if not inv.commands.ownsResponse(resultData) then return dbot.callback.default(resultData, retval) end
  EnableTrigger(dbot.pagesize.trigger.getName, false)
  if retval == DRL_RET_SUCCESS then
    if dbot.pagesize.pending ~= nil then dbot.pagesize.lines = dbot.pagesize.pending
    else retval = DRL_RET_TIMEOUT end
  end
  dbot.pagesize.pending = nil
  dbot.callback.default(resultData, retval)
end -- dbot.pagesize.resultFn


----------------------------------------------------------------------------------------------------
--
-- Module to execute one more commands on the mud server side
--
-- Fast commands keep the existing immediate Execute contract. Safe commands
-- are owned requests: one request acquires response parsers, with one deadline
-- covering queueing and execution. The coordinator completes on a protocol tag
-- or a unique fence. Interfering user input cancels capture and passes through.
-- See dinv_commands.lua; this API remains for existing domain workflows.
----------------------------------------------------------------------------------------------------

dbot.execute = { init = {}, fast = {}, safe = {}, queue = {},
  bypassPrefix = "DINV_BYPASS ", afkIsPending = false,
  quitIsPending = false, noteIsPending = false }

function dbot.execute.init.atActive()
  return DRL_RET_SUCCESS
end -- dbot.execute.init.atActive

function dbot.execute.fini(doSaveState)
  inv.commands.cancelAll(DRL_RET_UNINITIALIZED)
  dbot.execute.afkIsPending, dbot.execute.quitIsPending, dbot.execute.noteIsPending = false, false, false
  return DRL_RET_SUCCESS
end -- dbot.execute.fini

function dbot.execute.fast.command(command)
  return dbot.execute.fast.commands({command})
end -- dbot.execute.fast.command

function dbot.execute.fast.commands(commands)
  if not commands then return DRL_RET_INVALID_PARAM end
  for _, command in ipairs(commands) do Execute(command) end
  return DRL_RET_SUCCESS
end -- dbot.execute.fast.commands

function dbot.execute.safe.command(command, setupFn, setupData, resultFn, resultData)
  return dbot.execute.safe.commands({command}, setupFn, setupData, resultFn, resultData)
end -- dbot.execute.safe.command

function dbot.execute.safe.commands(commands, setupFn, setupData, resultFn, resultData, options)
  if not commands then return DRL_RET_INVALID_PARAM end
  local identification
  if setupFn == inv.items.identifyAtomicSetup or setupFn == inv.items.identifyItemSetupFn then
    identification = inv.items.identifyPkg
  end
  local requestOptions = {}
  for key, value in pairs(options or {}) do requestOptions[key] = value end
  requestOptions.cleanup, requestOptions.identification = inv.items.cleanupRequest, identification
  return inv.commands.enqueue(commands, setupFn, setupData, resultFn, resultData, requestOptions)
end -- dbot.execute.safe.commands

function dbot.execute.safe.blocking(commands, setupFn, setupData, resultFn, timeout, options)
  local result = dbot.callback.new()
  local retval = dbot.execute.safe.commands(commands, setupFn, setupData, resultFn, result, options)
  if retval ~= DRL_RET_SUCCESS then return retval end
  return dbot.callback.wait(result, timeout)
end -- dbot.execute.safe.blocking

function dbot.execute.queue.bypass(command)
  inv.commands.send(command)
  return DRL_RET_SUCCESS
end -- dbot.execute.queue.bypass

function dbot.execute.queue.fence()
  return dbot.execute.safe.blocking({}, nil, nil, dbot.callback.default, 30)
end -- dbot.execute.queue.fence

function dbot.execute.new()
  return {}
end -- dbot.execute.new


----------------------------------------------------------------------------------------------------
-- Module to assist with callback management
--
-- dbot.callback.new()
-- dbot.callback.setReturn(resultData, value)
-- dbot.callback.getReturn(resultData)
-- dbot.callback.isDone(resultData) -- returns true or false
-- dbot.callback.default(resultData, retval))
-- dbot.callback.wait(resultData, timeoutInSec, periodInSec)
--
----------------------------------------------------------------------------------------------------

dbot.callback = {}


function dbot.callback.new()
  return { isDone = false, retval = DRL_RET_UNINITIALIZED }
end -- dbot.callback.new


function dbot.callback.setReturn(resultData, value)
  if (resultData == nil) then
    dbot.warn("dbot.callback.setReturn: callback parameter is nil")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (value == nil) then
    dbot.warn("dbot.callback.setReturn: missing value parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  resultData.retval = value

  return DRL_RET_SUCCESS
end -- dbot.callback.setReturn


function dbot.callback.getReturn(resultData)
  if (resultData == nil) then
    dbot.warn("dbot.callback.getReturn: callback parameter is nil")
    return DRL_RET_INVALID_PARAM
  end -- if

  return resultData.retval
end -- dbot.callback.getReturn


function dbot.callback.isDone(resultData) -- returns true or false
  if (resultData ~= nil) then
    return resultData.isDone
  else
    return false
  end -- if
end -- dbot.callback.isDone


function dbot.callback.default(resultData, retval)
  inv.runtime.resolve(resultData, retval or DRL_RET_INTERNAL_ERROR)
end -- dbot.callback.default

function dbot.callback.wait(resultData, timeout, period)
  if type(resultData) ~= "table" or not tonumber(timeout) then return DRL_RET_INVALID_PARAM end
  return inv.runtime.await(resultData, tonumber(timeout))
end -- dbot.callback.wait

----------------------------------------------------------------------------------------------------
-- Module to retrieve remote files
--
-- dbot.remote.get(url, protocol)
-- dbot.remote.getCR()
--
----------------------------------------------------------------------------------------------------

dbot.remote        = {}
dbot.remote.getPkg = nil

-- Blocks and then returns file, retval
-- Must be called from within a co-routine
function dbot.remote.get(url, protocol)
  local retval   = DRL_RET_SUCCESS
  local fileData = nil

  if (url == nil) or (url == "") then
    dbot.warn("dbot.remote.get: missing url parameter")
    return fileData, DRL_RET_INVALID_PARAM
  end -- if

  if (protocol == nil) or (protocol == "") then
    dbot.warn("dbot.remote.get: missing protocol parameter")
    return fileData, DRL_RET_INVALID_PARAM
  end -- if

  if (dbot.remote.getPkg ~= nil) then
    dbot.info("Skipping remote request: another request is in progress")
    return fileData, DRL_RET_BUSY
  end -- if

  dbot.remote.getPkg          = {}
  dbot.remote.getPkg.url      = url
  dbot.remote.getPkg.protocol = protocol
  dbot.remote.getPkg.isDone   = false

  inv.runtime.start(dbot.remote.getCR, dbot.remote, "getPkg")

  local timeout = 10
  local totTime = 0
  while (dbot.remote.getPkg.isDone == false) do
    if (totTime > timeout) then
      retval = DRL_RET_TIMEOUT
      break
    end -- if

    inv.runtime.sleep(drlSpinnerPeriodDefault)
    totTime = totTime + drlSpinnerPeriodDefault
  end -- while

  if (dbot.remote.getPkg ~= nil) and (dbot.remote.getPkg.fileData ~= nil) then
    fileData = dbot.remote.getPkg.fileData
  else
    dbot.warn("dbot.remote.get: Failed to find data for file \"@G" .. url .. "@W\"")
    retval = DRL_RET_MISSING_ENTRY
  end -- if

  dbot.remote.getPkg = nil
  return fileData, retval

end -- dbot.remote.get


function dbot.remote.getCR()
  local retval = DRL_RET_SUCCESS

  if (dbot.remote.getPkg == nil) or (dbot.remote.getPkg.url == nil) then
    dbot.error("dbot.remote.getCR: remote package is nil or corrupted!")
    dbot.remote.getPkg = nil
    return DRL_RET_INTERNAL_ERROR
  end -- if

  -- Fetch the URL, following HTTP redirects (3xx) up to a small hop limit.  Most
  -- of our fetches (raw.githubusercontent.com) return 200 directly, so the loop
  -- body runs exactly once for them.  Release-asset downloads
  -- (github.com/.../releases/latest/download/...) redirect through one or more
  -- hosts before reaching 200, so we follow the "location" header each time.
  -- (LuaSocket lower-cases all header keys, hence headers.location.)
  local url          = dbot.remote.getPkg.url
  local protocol     = dbot.remote.getPkg.protocol
  local maxRedirects = 5

  for hop = 0, maxRedirects do
    local urlThread = async.request(url, protocol)

    if (urlThread == nil) then
      dbot.warn("dbot.remote.getCR: Failed to create thread requesting remote data")
      retval = DRL_RET_INTERNAL_ERROR
      break
    end -- if

    local timeout = 10
    local totTime = 0
    while (urlThread:alive()) do
      if (totTime > timeout) then
        retval = DRL_RET_TIMEOUT
        break
      end -- if

      inv.runtime.sleep(drlSpinnerPeriodDefault)
      totTime = totTime + drlSpinnerPeriodDefault
    end -- while

    if (retval == DRL_RET_TIMEOUT) then
      dbot.warn("dbot.remote.getCR: Timed out retrieving \"@G" .. url .. "@W\"")
      break
    end -- if

    local remoteRet, page, status, headers, fullStatus = urlThread:join()

    if (status == 200) then
      dbot.remote.getPkg.fileData = page
      break

    elseif (type(status) == "number") and (status >= 300) and (status < 400) then
      -- Redirect: follow the location header on the next hop
      local location = headers and (headers.location or headers["Location"])
      if (location == nil) or (location == "") then
        dbot.warn("dbot.remote.getCR: redirect (" .. tostring(status) ..
                  ") with no location header")
        retval = DRL_RET_INTERNAL_ERROR
        break
      end -- if
      if (hop == maxRedirects) then
        dbot.warn("dbot.remote.getCR: too many redirects (>" .. maxRedirects .. ")")
        retval = DRL_RET_INTERNAL_ERROR
        break
      end -- if
      dbot.debug("dbot.remote.getCR: following redirect (" .. tostring(status) ..
                 ") to " .. location)
      url = location

    else
      dbot.warn("dbot.remote.getCR: Failed to retrieve remote file (status " ..
                tostring(status) .. ")")
      retval = DRL_RET_INTERNAL_ERROR
      break
    end -- if
  end -- for

  dbot.remote.getPkg.isDone = true

  return retval
end -- dbot.remote.getCR


----------------------------------------------------------------------------------------------------
-- dbot.version: Track the plugin's version and changelog and update the plugin
--
-- dbot.version.changelog.get(minVersion, endTag)
-- dbot.version.changelog.getCR()
-- dbot.version.changelog.displayChanges(minVersion, changeLog)
-- dbot.version.changelog.displayChange(changeLogEntries)
--
-- dbot.version.update.release(mode, endTag)
-- dbot.version.update.releaseCR()
-- Note: dbot.version.update is derived from a plugin written by Arcidayne.  Thanks Arcidayne!
----------------------------------------------------------------------------------------------------

dbot.version               = {}

dbot.version.changelog     = {}
dbot.version.changelog.pkg = nil

dbot.version.update        = {}
dbot.version.update.pkg    = nil

drlDbotUpdateCheck         = "check"
drlDbotUpdateInstall       = "install"

drlDbotChangeLogTypeFix    = "@RFix@W"
drlDbotChangeLogTypeNew    = "@GNew@W"
drlDbotChangeLogTypeMisc   = "@yMsc@W"


function dbot.version.changelog.get(minVersion, endTag)
  local url      = "https://raw.githubusercontent.com/rodarvus/dinv/master/dinv.changelog"
  local protocol = "HTTPS"

  if (dbot.version.changelog.pkg ~= nil) then
    dbot.info("Skipping changelog request: another request is in progress")
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_BUSY)
  end -- if

  dbot.version.changelog.pkg            = {}
  dbot.version.changelog.pkg.url        = url
  dbot.version.changelog.pkg.protocol   = protocol
  dbot.version.changelog.pkg.minVersion = minVersion or 0
  dbot.version.changelog.pkg.endTag     = endTag

  inv.runtime.start(dbot.version.changelog.getCR, dbot.version.changelog, "pkg")

  return DRL_RET_SUCCESS
end -- dbot.version.changelog.get


function dbot.version.changelog.getCR()

  if (dbot.version.changelog.pkg == nil) then
    dbot.error("dbot.version.changelog.getCR: Change log package is missing!")
    return inv.tags.stop(invTagsVersion, "missing end tag", DRL_RET_INTERNAL_ERROR)
  end -- if

  local endTag = dbot.version.changelog.pkg.endTag

  local fileData, retval = dbot.remote.get(dbot.version.changelog.pkg.url,
                                           dbot.version.changelog.pkg.protocol)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.version.changelog.getCR: Failed to retrieve remote changelog file: " ..
              dbot.retval.getString(retval))
  elseif (fileData == nil) then
    dbot.info("No changelog information was found.")

  else
    loadstring(fileData)()
    if (dbot.changelog == nil) then
      dbot.warn("dbot.version.changelog.getCR: Invalid changelog format detected")
      retval = DRL_RET_INTERNAL_ERROR
    else
      retval = dbot.version.changelog.displayChanges(dbot.version.changelog.pkg.minVersion, dbot.changelog)
    end -- if
  end -- if

  dbot.version.changelog.pkg = nil

  return inv.tags.stop(invTagsVersion, endTag, retval)

end -- dbot.version.changelog.getCR


function dbot.version.changelog.displayChanges(minVersion, changeLog)
  local sortedLog = {}

  for k, v in pairs(changeLog) do
    table.insert(sortedLog, { version = tonumber(k) or 0, changes = v})
  end -- for
  table.sort(sortedLog, function (v1, v2) return v1.version < v2.version end)

  for _, clog in ipairs(sortedLog) do
    if (clog.version > minVersion) then
      dbot.version.changelog.displayChange(clog)
    end -- if
  end -- for

  return DRL_RET_SUCCESS
end -- dbot.version.changelog.displayChanges


-- Format of entry is: { version = 2.0004,
--                       changes = { { change = drlDbotChangeLogTypeXYZ, desc = "what changed" }
--                                 }
--                     }
function dbot.version.changelog.displayChange(changeLogEntries)
  local retval = DRL_RET_SUCCESS

  if (changeLogEntries == nil) then
    dbot.warn("dbot.version.changelog.displayChange: Change entries are missing!")
    return DRL_RET_INVALID_PARAM
  end -- if

  dbot.print(string.format("@Cv%1.4f@W", changeLogEntries.version))
  for _, logEntry in ipairs(changeLogEntries.changes) do
    dbot.print(string.format("@W    (%s): %s", logEntry.change, logEntry.desc))
  end -- for

  return retval
end -- dbot.version.changelog.displayChange


dbot.version.update.baseUrl = "https://raw.githubusercontent.com/rodarvus/dinv/master/"

function dbot.version.update.release(mode, endTag)
  local retval = DRL_RET_SUCCESS

  if (mode == nil) or ((mode ~= drlDbotUpdateCheck) and (mode ~= drlDbotUpdateInstall)) then
    dbot.warn("dbot.version.update.release: Missing or invalid mode parameter")
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_INVALID_PARAM)
  end -- if

  if (dbot.version.update.pkg ~= nil) then
    dbot.info("Skipping update request: another update request is in progress")
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_BUSY)
  end -- if

  dbot.version.update.pkg          = {}
  dbot.version.update.pkg.mode     = mode
  dbot.version.update.pkg.endTag   = endTag

  inv.runtime.start(dbot.version.update.releaseCR, dbot.version.update, "pkg")

  return retval
end -- dbot.version.update.release


-- Read the local manifest file. Returns parsed table or nil.
function dbot.version.update.readLocalManifest()
  local pluginDir = GetPluginInfo(GetPluginID(), 20)
  local f = io.open(pluginDir .. "dinv.manifest", "r")
  if not f then return nil end

  local data = f:read("*a")
  f:close()

  local ok, manifest = pcall(json.decode, data)
  if ok and manifest then return manifest end
  return nil
end


-- Release-asset base URL for single-file installs.  "latest/download" always
-- redirects to the newest published release's assets; dbot.remote follows the
-- redirect chain.
dbot.version.update.releaseAssetUrl = "https://github.com/rodarvus/dinv/releases/latest/download/"


-- A "single-file" install is dinv_single.xml dropped in by itself: the separate
-- module files (and dinv.manifest) are not on disk.  Detect by the absence of
-- dinv_init.lua next to the plugin.
function dbot.version.update.isSingleFile()
  local pluginDir = GetPluginInfo(GetPluginID(), 20)
  local f = io.open(pluginDir .. "dinv_init.lua", "r")
  if f then f:close() return false end
  return true
end -- dbot.version.update.isSingleFile


-- Update path for single-file installs.  The installable artifact is the latest
-- *release* asset (dinv_single.xml), so we read the release's manifest for the
-- version (master can be ahead of the latest release) and, on install, download
-- the single file and swap it over the running plugin file.
function dbot.version.update.singleFileCR(mode, endTag)
  local protocol = "HTTPS"
  local assetUrl = dbot.version.update.releaseAssetUrl

  dbot.info("Checking for updates (single-file install)...")

  -- The release's manifest tells us the latest released version
  local manifestData, dlRetval = dbot.remote.get(assetUrl .. "dinv.manifest", protocol)
  if (dlRetval ~= DRL_RET_SUCCESS) or (manifestData == nil) then
    dbot.warn("Failed to retrieve the latest release manifest")
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, dlRetval or DRL_RET_MISSING_ENTRY)
  end -- if

  local ok, remoteManifest = pcall(json.decode, manifestData)
  if not ok or not remoteManifest or not remoteManifest.plugin_version then
    dbot.warn("Failed to parse the latest release manifest")
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_INTERNAL_ERROR)
  end -- if

  local currentVersion = GetPluginInfo(GetPluginID(), 19) or 0
  local currentVerStr  = string.format("%1.4f", currentVersion)
  local remoteVersion  = tonumber(remoteManifest.plugin_version or "") or 0
  local remoteVerStr   = string.format("%1.4f", remoteVersion)

  if (remoteVersion <= currentVersion) then
    if (remoteVersion < currentVersion) then
      dbot.info("Your plugin (v" .. currentVerStr ..
                ") is newer than the latest official release (v" .. remoteVerStr .. ")")
    else
      dbot.info("You are running the most recent release (v" .. currentVerStr .. ")")
    end -- if
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_SUCCESS)
  end -- if

  dbot.info("You are running v" .. currentVerStr .. ", latest release is v" .. remoteVerStr)

  if (mode == drlDbotUpdateCheck) then
    dbot.info("This is a single-file install.  Run \"@G" .. pluginNameCmd ..
              " version update confirm@W\" to download and install the new dinv_single.xml.")
    dbot.info("Changes since your version:")
    dbot.version.update.pkg = nil
    return dbot.version.changelog.get(currentVersion, endTag)
  end -- if

  -- Install: download the single-file build and swap it over the running plugin file
  dbot.info("Updating to v" .. remoteVerStr .. " (single-file)...")
  dbot.info("Please do not enter anything until the update completes")

  local fileData, fileRetval = dbot.remote.get(assetUrl .. "dinv_single.xml", protocol)
  if (fileRetval ~= DRL_RET_SUCCESS) or (fileData == nil) then
    dbot.warn("Failed to download dinv_single.xml: " .. dbot.retval.getString(fileRetval or -1))
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, fileRetval or DRL_RET_MISSING_ENTRY)
  end -- if

  local pluginFile = GetPluginInfo(GetPluginID(), 6)
  local tempPath   = pluginFile .. ".update_" .. string.format("%06x", math.random(0, 0xFFFFFF))

  local f = io.open(tempPath, "w")
  if not f then
    dbot.warn("Failed to open a temp file for the update")
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_INTERNAL_ERROR)
  end -- if
  f:write(fileData)
  f:close()

  -- Swap the downloaded file over the running plugin file (Windows requires the
  -- destination be removed first), then schedule a reload.  Only the temp file
  -- is touched until the download fully succeeds, so a failed download never
  -- clobbers the running plugin.
  os.remove(pluginFile)
  local renamed, err = os.rename(tempPath, pluginFile)
  if not renamed then
    dbot.error("Failed to install the update: " .. (err or "unknown"))
    os.remove(tempPath)
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_INTERNAL_ERROR)
  end -- if

  dbot.info("Update to v" .. remoteVerStr .. " complete. Reloading plugin...")
  dbot.version.update.pkg = nil
  dbot.reload()

  return inv.tags.stop(invTagsVersion, endTag, DRL_RET_SUCCESS)
end -- dbot.version.update.singleFileCR


function dbot.version.update.releaseCR()
  if (dbot.version.update.pkg == nil) or (dbot.version.update.pkg.mode == nil) then
    dbot.error("dbot.version.update.releaseCR: Missing or invalid update package detected")
    return inv.tags.stop(invTagsVersion, "end tag is nil", DRL_RET_INVALID_PARAM)
  end -- if

  local endTag   = dbot.version.update.pkg.endTag
  local mode     = dbot.version.update.pkg.mode
  local baseUrl  = dbot.version.update.baseUrl
  local protocol = "HTTPS"
  local retval   = DRL_RET_SUCCESS

  -- Single-file installs (dinv_single.xml alone) have no local module files or
  -- manifest and can't use the per-file path below; update them from the latest
  -- release asset instead.
  if dbot.version.update.isSingleFile() then
    return dbot.version.update.singleFileCR(mode, endTag)
  end -- if

  -- Download remote manifest
  dbot.info("Checking for updates...")
  local manifestData, dlRetval = dbot.remote.get(baseUrl .. "dinv.manifest", protocol)
  if (dlRetval ~= DRL_RET_SUCCESS) or (manifestData == nil) then
    dbot.warn("Failed to retrieve remote manifest")
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, dlRetval or DRL_RET_MISSING_ENTRY)
  end -- if

  local ok, remoteManifest = pcall(json.decode, manifestData)
  if not ok or not remoteManifest or not remoteManifest.files then
    dbot.warn("Failed to parse remote manifest")
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_INTERNAL_ERROR)
  end -- if

  -- Read local manifest
  local localManifest = dbot.version.update.readLocalManifest()

  -- Compare versions
  local currentVersion = GetPluginInfo(GetPluginID(), 19) or 0
  local currentVerStr  = string.format("%1.4f", currentVersion)
  local remoteVersion  = tonumber(remoteManifest.plugin_version or "") or 0
  local remoteVerStr   = string.format("%1.4f", remoteVersion)

  if (remoteVersion == currentVersion) then
    dbot.info("You are running the most recent plugin (v" .. currentVerStr .. ")")
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_SUCCESS)

  elseif (remoteVersion < currentVersion) then
    dbot.warn("Your current plugin (v" .. currentVerStr .. ") " ..
              "is newer than the latest official release (v" .. remoteVerStr .. ")")
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_VER_MISMATCH)
  end -- if

  -- Build list of changed files
  local changedFiles = {}
  local removedFiles = {}
  local localFiles = (localManifest and localManifest.files) or {}

  -- Files that are new or modified in the remote manifest
  for fileName, remoteVer in pairs(remoteManifest.files) do
    local localVer = localFiles[fileName]
    if localVer ~= remoteVer then
      table.insert(changedFiles, fileName)
    end -- if
  end -- for

  -- Files that exist locally but are absent from the remote manifest (removed)
  for fileName, _ in pairs(localFiles) do
    if not remoteManifest.files[fileName] then
      table.insert(removedFiles, fileName)
    end -- if
  end -- for

  if (#changedFiles == 0) and (#removedFiles == 0) then
    dbot.info("All files are up to date (v" .. currentVerStr .. ")")
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_SUCCESS)
  end -- if

  -- Report changes
  dbot.info("You are running v" .. currentVerStr .. ", latest version is v" .. remoteVerStr)
  if (#changedFiles > 0) then
    dbot.info(#changedFiles .. " file(s) need updating:")
    for _, fileName in ipairs(changedFiles) do
      dbot.print("  @G" .. fileName .. "@W")
    end -- for
  end -- if
  if (#removedFiles > 0) then
    dbot.info(#removedFiles .. " file(s) will be removed:")
    for _, fileName in ipairs(removedFiles) do
      dbot.print("  @R" .. fileName .. "@W")
    end -- for
  end -- if

  -- Check mode
  if (mode == drlDbotUpdateCheck) then
    dbot.info("Changes since your last update:")
    dbot.version.update.pkg = nil
    return dbot.version.changelog.get(currentVersion, endTag)
  end -- if

  -- Install mode: download changed files
  dbot.info("Updating plugin to v" .. remoteVerStr .. "...")
  dbot.info("Please do not enter anything until the update completes")

  local pluginDir = GetPluginInfo(GetPluginID(), 20)
  local updateSuffix = ".update_" .. string.format("%06x", math.random(0, 0xFFFFFF))
  local tempFiles = {}  -- { {tempPath, finalPath}, ... }
  local downloadOk = true

  -- Download each changed file to a temp name
  for _, fileName in ipairs(changedFiles) do
    dbot.info("Downloading @G" .. fileName .. "@W...")
    local fileData, fileRetval = dbot.remote.get(baseUrl .. fileName, protocol)
    if (fileRetval ~= DRL_RET_SUCCESS) or (fileData == nil) then
      dbot.warn("Failed to download " .. fileName .. ": " .. dbot.retval.getString(fileRetval or -1))
      downloadOk = false
      break
    end -- if

    local tempPath = pluginDir .. fileName .. updateSuffix
    local finalPath = pluginDir .. fileName
    local f = io.open(tempPath, "w")
    if not f then
      dbot.warn("Failed to write temp file for " .. fileName)
      downloadOk = false
      break
    end -- if
    f:write(fileData)
    f:close()

    table.insert(tempFiles, { temp = tempPath, final = finalPath })
  end -- for

  -- Also save the remote manifest as a temp file
  if downloadOk then
    local manifestTemp = pluginDir .. "dinv.manifest" .. updateSuffix
    local manifestFinal = pluginDir .. "dinv.manifest"
    local f = io.open(manifestTemp, "w")
    if f then
      f:write(manifestData)
      f:close()
      table.insert(tempFiles, { temp = manifestTemp, final = manifestFinal })
    else
      dbot.warn("Failed to write temp manifest file")
      downloadOk = false
    end -- if
  end -- if

  if not downloadOk then
    -- Clean up temp files on failure
    dbot.warn("Update failed. Cleaning up temporary files...")
    for _, tf in ipairs(tempFiles) do
      os.remove(tf.temp)
    end -- for
    dbot.version.update.pkg = nil
    return inv.tags.stop(invTagsVersion, endTag, DRL_RET_INTERNAL_ERROR)
  end -- if

  -- All downloads succeeded: rename temp files to final names
  for _, tf in ipairs(tempFiles) do
    os.remove(tf.final)  -- remove old file first (Windows requires this for rename)
    local ok, err = os.rename(tf.temp, tf.final)
    if not ok then
      dbot.error("Failed to install " .. tf.final .. ": " .. (err or "unknown"))
      -- Continue trying other files rather than leaving a partial state
    end -- if
  end -- for

  -- Remove files that are no longer in the remote manifest
  for _, fileName in ipairs(removedFiles) do
    local removePath = pluginDir .. fileName
    local ok = os.remove(removePath)
    if ok then
      dbot.debug("Removed obsolete file: " .. fileName)
    else
      dbot.debug("Could not remove obsolete file: " .. fileName)
    end -- if
  end -- for

  dbot.info("Update to v" .. remoteVerStr .. " complete. Reloading plugin...")
  dbot.version.update.pkg = nil
  dbot.reload()

  return inv.tags.stop(invTagsVersion, endTag, retval)
end -- dbot.version.update.releaseCR
