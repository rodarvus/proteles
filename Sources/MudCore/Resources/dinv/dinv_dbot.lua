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
  local retval = DRL_RET_SUCCESS
  local configVal = false

  if (configMode == nil) or (configMode == "") then
    dbot.warn("dbot.gmcp.getConfig: Missing configMode")
    return configVal, DRL_RET_INVALID_PARAM
  end -- if

  -- Clear out the current state and wait for a new value to arrive
  dbot.gmcp.currentState.configMode = nil  
  check (Execute("sendgmcp config " .. configMode))

  -- Spin until gmcp gives us the value
  local totTime = 0
  local timeout = 5
  retval = DRL_RET_TIMEOUT
  while (totTime <= timeout) do

    local gmcpValue = dbot.gmcp.currentState[configMode]
    if (gmcpValue == "YES") then 
      configVal = true
      retval = DRL_RET_SUCCESS
      break
    elseif (gmcpValue == "NO") then
      configVal = false
      retval = DRL_RET_SUCCESS
      break
    end -- if

    wait.time(drlSpinnerPeriodDefault)
    totTime = totTime + drlSpinnerPeriodDefault
  end -- while

  if (retval == DRL_RET_TIMEOUT) then
    dbot.warn("dbot.gmcp.getConfig: Timed out waiting for response from gmcp for config mode \"" ..
              configMode .. "\"")
  end -- if

  return configVal, retval

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


-- Automatic backup before dinv build confirm (only if database has items).
function dbot.backup.preBuild()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  -- Only backup if we have existing items
  local count = 0
  for row in db:nrows("SELECT COUNT(*) as cnt FROM items") do
    count = row.cnt
  end

  if count == 0 then
    dbot.debug("dbot.backup.preBuild: Skipping pre-build backup (no items in database)")
    return DRL_RET_SUCCESS
  end

  local backupName = "pre-build"
  dbot.info("Creating automatic backup before build...")
  return dbot.backup.create(backupName, nil)
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

  wait.make(dbot.backup.restoreCR)

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

dbot.prompt.isEnabled = true -- by default, assume the prompt is enabled if we can't get the real status


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

  dbot.prompt.isEnabled = true

  -- NOTE: if we ever add persistent data to this module we should use the doSaveState param to determine
  -- if we need to save it

  return DRL_RET_SUCCESS
end -- dbot.prompt.fini


function dbot.prompt.disable()
  --dbot.debug("prompt disable: start statusEnables = " .. (dbot.prompt.statusEnables or "nil"))
  if (dbot.prompt.statusEnables ~= nil) then
    -- The moment we transition from having 1 enable to 0 enables, we disable the prompt.  Someone
    -- could call multiple consecutive disables but we'd only do the disabling once.  
    dbot.prompt.statusEnables = dbot.prompt.statusEnables - 1
    if (dbot.prompt.statusEnables == 0) then
      Execute("sendgmcp config prompt off")
    end -- if
  end -- if
end -- dbot.prompt.disable


function dbot.prompt.enable()
  --dbot.debug("prompt enable: start statusEnables = " .. (dbot.prompt.statusEnables or "nil"))
  if (dbot.prompt.statusEnables ~= nil) then
    dbot.prompt.statusEnables = dbot.prompt.statusEnables + 1
    if (dbot.prompt.statusEnables == 1) then
      Execute("sendgmcp config prompt on")
    end -- if
  end -- if
end -- dbot.prompt.enable


-- Disable the prompt and suppress empty lines
function dbot.prompt.hide()
  dbot.emptyLine.disable()
  dbot.prompt.disable()
end -- dbot.prompt.hide


function dbot.prompt.show()
  dbot.prompt.enable()

  -- TODO: This is an awkward situation.  We want to stop suppressing empty lines (resulting
  --       from some actions this plugin executes in the background) but we don't want to do
  --       that until all of the commands queued up on the server are executed.  Yes, we could
  --       do some extra synchronization to catch the end of the command queue, but that's
  --       more work than I want to deal with for this minor issue.  In the meantime, there
  --       might be one or two empty lines of output that show up near the end of a large
  --       operation.
  dbot.emptyLine.enable()
end -- dbot.prompt.show


function dbot.prompt.getStatusCR()
  local retval

  dbot.prompt.isEnabled, retval = dbot.gmcp.getConfig("prompt")
  if (retval == DRL_RET_SUCCESS) then
    if dbot.prompt.isEnabled then
      dbot.debug("prompt is @GENABLED@W")
      dbot.prompt.statusEnables = 1
    else
      dbot.debug("prompt is @RDISABLED@W")
      dbot.prompt.statusEnables = 0
    end -- if
  else
    dbot.warn("dbot.prompt.getStatusCR: Failed to get gmcpconfig response")
  end -- if

  -- Once we know the current state, we monitor when the user manually toggles the prompt so
  -- that we can keep our state up-to-date
  EnableTrigger(dbot.prompt.trigger.onToggleName, true)

  return retval
end -- dbot.prompt.getStatusCR


function dbot.prompt.trigger.onToggle(msg)

  if (msg == "You will no longer see prompts") then
    dbot.debug("dbot.prompt.trigger.onToggle: user manually turned the prompt off")
    dbot.prompt.statusEnables = 0
    inv.config.table.isPromptEnabled = false

  elseif (msg == "You will now see prompts") then
    dbot.debug("dbot.prompt.trigger.onToggle: user manually turned the prompt on")
    dbot.prompt.statusEnables = 1
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

  local isInvmonEnabled, retval = dbot.gmcp.getConfig("invmon")
  if (retval == DRL_RET_SUCCESS) then
    if isInvmonEnabled then
      dbot.debug("invmon is @GENABLED@W")
      dbot.invmon.statusEnables = 1
    else
      dbot.debug("invmon is @RDISABLED@W")
      dbot.invmon.statusEnables = 0
      dbot.warn("The " .. pluginNameAbbr .. " plugin requires invmon.  Please type \"invmon\" to enable it.")
    end -- if
  else
    dbot.warn("dbot.invmon.getStatusCR: Failed to get gmcpconfig response")
  end -- if

  -- Once we know the current state, we monitor when the user manually toggles invmon so
  -- that we can keep our state up-to-date
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
                      "^(.*)$",
                      "dbot.wish.trigger.fn(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11,
                      0, "", "", sendto.script, 0))

  check (EnableTrigger(dbot.wish.trigger.itemName, false)) -- default to off

  -- Kick off a timer to update the wishes.  It would be convenient to just run dbot.wish.get()
  -- right here instead of scheduling it to run 1 second from now.  However, there are cases where
  -- we our telnet options code detects that we are out of AFK causing us to run this init routine
  -- before GMCP notices that our state changed.  If that happens, no real harm is done and we simply
  -- reschedule the wish detection to try again later.  However, we can (probably) avoid that extra
  -- overhead if we simply give GMCP a chance to detect the state change so we are willing to wait
  -- an extra second here to give it that chance. 
  check (AddTimer(dbot.wish.timer.name, 0, 0, 1, "",
                  timer_flag.Enabled + timer_flag.Replace + timer_flag.OneShot,
                  "dbot.wish.get"))

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
  if (dbot.wish.inProgress == true) then
    dbot.info("Skipping request to get list of active wishes: another request is in progress")
    return DRL_RET_BUSY
  end -- if

  dbot.wish.inProgress = true

  wait.make(dbot.wish.getCR)

  return DRL_RET_SUCCESS
end -- dbot.wish.get


dbot.wish.fenceMsg = "DINV wish list fence"
function dbot.wish.getCR()
  local retval = DRL_RET_SUCCESS
  local charState = dbot.gmcp.getState()
  local pageLines, retval = dbot.pagesize.get()

  -- If we are not in the active state (i.e., AFK, sleeping, running, writing a note, etc.) then
  -- we can't get the list of wishes and we need to try again later
  if (charState ~= dbot.stateActive) then
    dbot.note("Skipping request to get list of active wishes: you are in the state \"" .. 
              dbot.gmcp.getStateString(charState) .. "\"")
    retval = DRL_RET_NOT_ACTIVE

  -- We are in the active state and can execute commands on the server side
  elseif (pageLines ~= nil) then

    -- Execute the "wish list" command
    -- TODO: Doh!  I just found the pagesize option in the "help telnet" helpfile.  This is in
    --       the telnet 102 interface and it lets you enable or disable paging easily.  It even
    --       remembers pagesize for you.  We may want to switch to that at some point.
    local commandArray = {}

    if (pageLines == 0) then
      table.insert(commandArray, "wish list")
      table.insert(commandArray, "echo " .. dbot.wish.fenceMsg) 
    else
      table.insert(commandArray, "pagesize 0")
      table.insert(commandArray, "wish list")
      table.insert(commandArray, "echo " .. dbot.wish.fenceMsg) 
      table.insert(commandArray, "pagesize " .. pageLines)
    end -- if

    local resultData = dbot.callback.new()
    retval = dbot.execute.safe.commands(commandArray, dbot.wish.setupFn, nil,
                                        dbot.wish.resultFn, resultData)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("dbot.wish.getCR: Failed to safely execute \"@Gwish list@W\": " ..
                dbot.retval.getString(retval))
    else
      -- Wait for confirmation that the "wish list" safe execution command completed
      retval = dbot.callback.wait(resultData, 30)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.note("Skipping \"wish list\" request: " .. dbot.retval.getString(retval))
      end -- if

      -- Wait for the wish trigger to complete
      local totTime = 0
      local timeout = 5
      while (dbot.wish.inProgress == true) do
        if (totTime > timeout) then
          dbot.debug("dbot.wish.getCR: Timed out getting list of wishes")
          retval = DRL_RET_TIMEOUT
          break
        end -- if

        wait.time(drlSpinnerPeriodDefault)
        totTime = totTime + drlSpinnerPeriodDefault
      end -- while
    end -- if

  else
    dbot.warn("Failed to detect # of lines in the page size: " .. dbot.retval.getString(retval))
  end -- if

  dbot.wish.inProgress = false

  -- If we weren't able to snag the list of wishes, try again later
  if (retval ~= DRL_RET_SUCCESS) then
    -- We can't add the timer directly because we are in the function called by that timer.  Instead,
    -- we use an intermediate timer to call back and start this timer again.  Yeah, it's a bit ugly...
    DoAfterSpecial(0.1, 
                   "AddTimer(dbot.wish.timer.name, 0, dbot.wish.timer.min, dbot.wish.timer.sec, \"\", " ..
                   "timer_flag.Enabled + timer_flag.Replace + timer_flag.OneShot, \"dbot.wish.get\")",
                   sendto.script)
  else
    -- We found the wishes.  Save them!
    dbot.debug("dbot.wish.getCR: detected purchased wishes!")
    dbot.wish.save()
  end -- if

  return retval
end -- dbot.wish.getCR


function dbot.wish.trigger.fn(line)
  local wishName = string.match(line, ".*[-][-] ([^ -]+)[ ]*$")

  -- We send a fence after checking with wishes to confirm that the wishes are done
  if (line == dbot.wish.fenceMsg) then
    EnableTrigger(dbot.wish.trigger.itemName, false)
    dbot.wish.inProgress = false
  end -- if

  if (wishName ~= nil) then
    dbot.wish.table[wishName] = true
    dbot.debug("Found wish name \"" .. wishName .. "\"")
  end -- if

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
  -- Add a trigger to watch for the start of the "wish list" output
  check (AddTriggerEx(dbot.wish.trigger.startName,
                      "^.*Base.*Cost.*Adjustment.*Your.*Cost.*Keyword.*$",
                      "EnableTrigger(dbot.wish.trigger.itemName, true)",
                      drlTriggerFlagsBaseline + trigger_flag.OneShot + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11,
                      0, "", "", sendto.script, 0))

  dbot.pagesize.hide()

end -- dbot.wish.setupFn


function dbot.wish.resultFn(resultData, retval)
  dbot.pagesize.show()

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

  retval = dbot.execute.safe.blocking({"pagesize"}, dbot.pagesize.setupFn, nil, dbot.pagesize.resultFn, 10)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.note("Skipped getting \"@Gpagesize@W\": " ..
              dbot.retval.getString(retval))
  else
    dbot.debug("Read current page size: " .. (dbot.pagesize.lines or "nil"))
  end -- if

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
    dbot.pagesize.lines = 0

  elseif (lines ~= nil) then
    dbot.pagesize.lines = lines

  end -- if
end -- dbot.pagesize.trigger.fn


function dbot.pagesize.setupFn(setupData)
  EnableTrigger(dbot.pagesize.trigger.getName, true)
end -- dbot.pagesize.setupFn


function dbot.pagesize.resultFn(resultData, retval)
  EnableTrigger(dbot.pagesize.trigger.getName, false)
  dbot.callback.default(resultData, retval)
end -- dbot.pagesize.resultFn


----------------------------------------------------------------------------------------------------
--
-- Module to execute one more commands on the mud server side
--
-- Commands come in two flavors:
--  1) "Fast": these are non-atomic and can be interrupted at any time.  There are no guarantees that
--     we will know when "fast" commands execute which means that we can't know for certain if triggers
--     are matching on any particular command output.
--  2) "Safe": safe commands guarantee that there will be no contention with any commands sent by the
--     user.  Safe commands run atomically on the mud at a time when we guarantee that no other commands
--     can execute on the mud server.  We do this by halting any new commands (via the OnPluginSend()
--     callback) and queuing up those commands to run after our atomic critical section completes.  We
--     guarantee that no user commands are lost and they will execute in the same order as they were
--     sent.  We also guarantee that user-supplied setup and cleanup callbacks will be executed during
--     the critical section without any contention from commands the user enters.  This allows us to
--     set up and clean up triggers and know that if a trigger goes off that it is triggering on the
--     output we want -- not something that the user entered at the command line.  Safe commands are
--     very convenient because they also let us cleanly handle cases where the user sleeps, enters
--     combat, or goes AFK unexpectedly.  Knowing that these state changes can't occur during one of
--     our "safe" critical sections greatly simplifies the code.
--
-- Here are the steps to safely run a background command without interference
--   1) Spin until we are in the "active" state (e.g., not AFK, sleeping, etc.)
--   2) Prevent new commands from going to the mud by watching for them in OnPluginSend() and queuing
--      them up for future execution
--   3) Add a one-shot trigger to catch a unique prefix message we will echo to the mud
--   4) Echo a unique prefix message to the mud
--   5) Wait for the trigger to hit and tell us that our unique prefix message was executed by
--      the mud.  No other commands can be pending at the mud's server side at this point.
--   6) Send the command(s) we want to run atomically
--   7) Execute any user-supplied setup callback to configure triggers
--   8) Capture the output (either success or failure) with user-supplied triggers 
--   9) Add a one-shot trigger to catch a unique suffix message we will echo to the mud
--  10) Send a unique suffix message to the mud
--  11) Wait until our trigger detects that the mud echoed our suffix
--  12) If the caller provided us a cleanup/result callback function, execute it now to let the caller
--      know that we are done and to tell the caller the result status
--  13) Send any pending commands that we queued up during the safe critical section
--  14) Unblock the OnPluginSend() callback so that new commands from the user go straight to the mud again
--
-- Functions:
--
-- dbot.execute.init.atActive()
-- dbot.execute.fini(doSaveState)
--
-- dbot.execute.fast.command(commandString)
-- dbot.execute.fast.commands(commandArray)
--
-- dbot.execute.safe.command(commandString, setupFn, setupData, resultFn, resultData)
-- dbot.execute.safe.commands(commandArray, setupFn, setupData, resultFn, resultData)
-- dbot.execute.safe.commandsCR()
-- dbot.execute.safe.blocking(commandArray, setupFn, setupData, resultFn, timeout)
--
-- dbot.execute.queue.enable()
-- dbot.execute.queue.disable()
-- dbot.execute.queue.pushFast(command)
-- dbot.execute.queue.pushSafe(commandArray, setupFn, setupData, resultFn, resultData)
-- dbot.execute.queue.pop()
-- dbot.execute.queue.fence()
-- dbot.execute.queue.bypass(command)
-- dbot.execute.queue.dequeueCR()
-- dbot.execute.queue.getCommandString(commandArray)
-- dbot.execute.new()
--
-- Data:
--   dbot.execute.table
--
----------------------------------------------------------------------------------------------------

dbot.execute                    = {}
dbot.execute.table              = {}
dbot.execute.queue              = {}
dbot.execute.init               = {}
dbot.execute.fast               = {}
dbot.execute.safe               = {}

dbot.execute.doDelayCommands    = false
dbot.execute.isDequeueRunning   = false
dbot.execute.afkIsPending       = false
dbot.execute.quitIsPending      = false
dbot.execute.noteIsPending      = false
dbot.execute.fenceIsDetected    = false
dbot.execute.bypassPrefix       = "DINV_BYPASS "

dbot.execute.trigger            = {}
dbot.execute.trigger.fenceName  = "drlDbotExecuteFenceTrigger"

drlDbotExecuteTypeFast = "fast"
drlDbotExecuteTypeSafe = "safe"


function dbot.execute.init.atActive()
  -- Placeholder: nothing to do here yet
  return DRL_RET_SUCCESS
end -- dbot.execute.init.atActive


function dbot.execute.fini(doSaveState)
  -- These are one-shot triggers and shouldn't exist here, but it doesn't hurt to verify
  -- that they are gone
  dbot.deleteTrigger(dbot.execute.trigger.fenceName)

  dbot.execute.doDelayCommands  = false
  dbot.execute.isDequeueRunning = false
  dbot.execute.afkIsPending     = false
  dbot.execute.quitIsPending    = false
  dbot.execute.noteIsPending    = false

  if (doSaveState) then
    -- Placeholder: If we ever add state to the execute module we should save it here
  end -- if

  return DRL_RET_SUCCESS
end -- dbot.execute.fini


function dbot.execute.fast.command(commandString)
  local origEchoInput = GetEchoInput()

  SetEchoInput(false)
  check (Execute(commandString))
  SetEchoInput(origEchoInput)

  return DRL_RET_SUCCESS
end -- dbot.execute.fast.command


-- This function simply pushes the commands in the command array to the mud server.  It doesn't
-- do any type of error checking or handling for the commands that are sent.  It does not require
-- a co-routine because it executes all in one shot and never yields.
function dbot.execute.fast.commands(commandArray)
  local retval = DRL_RET_SUCCESS

  if (commandArray == nil) then
    dbot.warn("dbot.execute.fast.commands: Missing command array parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- We don't want all of our commands to echo to the client.  Remember what the original echo
  -- state is so that we can restore that state when we are done.
  local origEchoInput = GetEchoInput()
  SetEchoInput(false)

  for _, command in ipairs(commandArray) do
    if (command ~= nil) and (command ~= "") then
      check (Execute(command))
    end -- if
  end -- for

  -- Restore the echo state before we return
  SetEchoInput(origEchoInput)
  
  return retval
end -- dbot.execute.fast.commands


-- This is a special case for the dbot.execute.safe.commands() call which uses just a
-- single command string.  The command is run atomically with nothing else in the mud's
-- command queue to interfere with it.
function dbot.execute.safe.command(commandString, setupFn, setupData, resultFn, resultData)
  local commandArray = {}
  table.insert(commandArray, commandString)

  return dbot.execute.safe.commands(commandArray, setupFn, setupData, resultFn, resultData)
end -- dbot.execute.safe.command


function dbot.execute.safe.commands(commandArray, setupFn, setupData, resultFn, resultData)
  local retval

  -- Enter a critical section if one isn't already in progress
  dbot.execute.queue.enable()

  -- Push the current request onto the end of the command queue
  retval = dbot.execute.queue.pushSafe(commandArray, setupFn, setupData, resultFn, resultData)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.execute.safe.commads: Failed to push request onto queue: " ..
              dbot.retval.getString(retval))
  else
    -- We just added a new command to the command queue.  If we don't already have a 
    -- co-routine processing commands on that queue, start one now.
    if (not dbot.execute.queue.isDequeueRunning) then
      dbot.execute.queue.isDequeueRunning = true
      wait.make(dbot.execute.queue.dequeueCR)
    end -- if
  end -- if

  return retval
end -- dbot.execute.safe.commands


function dbot.execute.safe.blocking(commandArray, setupFn, setupData, resultFn, timeout)

  if (commandArray == nil) then
    dbot.warn("dbot.execute.safe.blocking: Missing command array parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  timeout = tonumber(timeout or "")
  if (timeout == nil) then
    dbot.warn("dbot.execute.safe.blocking: Missing timeout parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- If there is nothing to do, do it successfully :)
  if (#commandArray < 1) then
    return DRL_RET_SUCCESS
  end -- if

  local resultData = dbot.callback.new()

  local retval = dbot.execute.safe.commands(commandArray, setupFn, setupData, resultFn, resultData)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.debug("dbot.execute.safe.blocking: Failed to execute command array: " ..
               dbot.retval.getString(retval))
  else
    -- Wait for the callback to confirm that the safe execution completed
    retval = dbot.callback.wait(resultData, timeout)
  end -- if

  return retval
end -- dbot.execute.safe.blocking


function dbot.execute.queue.enable()
  dbot.execute.doDelayCommands = true
end -- dbot.execute.queue.get


function dbot.execute.queue.disable()
  dbot.execute.doDelayCommands = false
end -- dbot.execute.queue.get


-- command table format:
--   { commandType  = drlDbotExecuteTypeFast,  -- or drlDbotExecuteTypeSafe
--     commands     = { "command 1",
--                      "command 2",
--                      ...
--                      "command N"
--                    }
--     setupFn      = mySetupFunctionCallback
--     setupData    = mySetupDataParameter
--     resultFn     = myResultFunctionCallback
--     resultData   = myResultDataParameter
--   }
function dbot.execute.queue.pushFast(command)
  local commandEntry

  if (command == nil) then
    dbot.warn("dbot.execute.queue.pushFast: command is missing")
    return DRL_RET_INVALID_PARAM
  end -- if

  commandEntry              = {}
  commandEntry.commandType  = drlDbotExecuteTypeFast
  commandEntry.commands     = { command }
  commandEntry.setupFn      = nil
  commandEntry.setupData    = nil
  commandEntry.resultFn     = nil
  commandEntry.resultData   = nil 

  table.insert(dbot.execute.table, commandEntry)

  dbot.debug("Queued fast command: \"@G" .. command .. "@W\"")

  return DRL_RET_SUCCESS
end -- dbot.execute.queue.pushFast


function dbot.execute.queue.pushSafe(commandArray, setupFn, setupData, resultFn, resultData)
  local commandEntry

  if (commandArray == nil) then
    dbot.warn("dbot.execute.queue.pushSafe: command array is missing")
    return DRL_RET_INVALID_PARAM
  end -- if

  commandEntry              = {}
  commandEntry.commandType  = drlDbotExecuteTypeSafe
  commandEntry.commands     = commandArray
  commandEntry.setupFn      = setupFn
  commandEntry.setupData    = setupData
  commandEntry.resultFn     = resultFn
  commandEntry.resultData   = resultData

  table.insert(dbot.execute.table, commandEntry)

  local commandString = dbot.execute.queue.getCommandString(commandArray)
  dbot.debug("Queued safe commands: \"@G" .. commandString .. "@W\"")

  return DRL_RET_SUCCESS
end -- dbot.execute.queue.pushSafe


function dbot.execute.queue.pop()
  local commandEntry = table.remove(dbot.execute.table, 1)

  return commandEntry
end -- dbot.execute.queue.pop


-- We need a unique prefix to attach to a fence command so that we don't confuse one fence
-- with another.  The simplest way to do that is to simply count fence commands and prepend
-- the count to the fence name.
dbot.execute.queue.fenceCounter = 1

-- The fence call sends an echo command to the mud server and blocks until the echo is detected.
-- This is very useful in conjuction with our OnPluginSend() code that queues up and delays user
-- commands.  If we delay new commands from going to the mud and we detect our fence output, then
-- we know that no other commands are pending on the mud server and there won't be interference
-- on what we send next.
--
-- We only call fence() from within a critical section where we have checked that we are in a
-- user state that allows the fence to proceed.  We don't need to worry about being AFK here.
function dbot.execute.queue.fence()

  local uniqueString = "{ DINV fence " .. dbot.execute.queue.fenceCounter .. " }"

  -- We will spin on this until we match the fence command in our trigger
  dbot.execute.fenceIsDetected = false

  -- Add a one-shot trigger to catch the fence message that we will echo to the mud
  check (AddTriggerEx(dbot.execute.trigger.fenceName,
                      "^" .. uniqueString .. "$",
                      "dbot.execute.fenceIsDetected = true",
                      drlTriggerFlagsBaseline + trigger_flag.OneShot + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11, 0, "", "", sendto.script, 0))

  -- If we are blocking new commands, we must explicitly bypass that protection in order to send
  -- a command to the mud server.
  local retval = dbot.execute.queue.bypass("echo " .. uniqueString)
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("dbot.execute.queue.fence: Failed to bypass command: " .. dbot.retval.getString(retval))
    return retval
  end -- if

  -- Spin until we have confirmation that the mud received the fence message or until we detect
  -- that we are in a state that will prevent the message from completing
  local totTime = 0
  local timeout = 30 -- wait a while since we there might be a lot of stuff queued up on the server
  while (dbot.execute.fenceIsDetected == false) do
    local charState = dbot.gmcp.getState()

    if (inv.state == invStateHalted) then
      dbot.note("Skipping fence request: plugin is halted!")
      retval = DRL_RET_UNINITIALIZED
      break

    elseif (totTime > timeout) then
      dbot.note("Skipping fence request: fence message timed out")
      retval = DRL_RET_TIMEOUT
      break

    elseif ((charState ~= dbot.stateActive) and
            (charState ~= dbot.stateCombat) and
            (charState ~= dbot.stateSleeping) and
            (charState ~= dbot.stateRunning)) then
      dbot.note("Skipping fence request: you are in the \"@C" .. dbot.gmcp.getStateString(charState) ..
                "@W\" state")
      retval = DRL_RET_NOT_ACTIVE
      break
    end -- if

    wait.time(drlSpinnerPeriodDefault)
    totTime = totTime + drlSpinnerPeriodDefault
  end -- while

  -- Note: You might think that we'd want to delete the fence trigger if there was an error
  --       and the trigger is still pending.  However, there is a chance that the fence echo
  --       is still pending on the server side so we'd like to keep the trigger around as long
  --       as possible to suppress the fence echo -- just in case.  It won't hurt anything
  --       because the next fence will overwrite the previous fence trigger.

  dbot.execute.queue.fenceCounter = dbot.execute.queue.fenceCounter + 1

  return retval
end -- dbot.execute.queue.fence


function dbot.execute.queue.bypass(command)
  if (command == nil) then
    dbot.warn("dbot.execute.queue.bypass: missing command parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  --dbot.note("Bypassing command \"@G" .. command .. "@W\"")
  check (SendNoEcho(dbot.execute.bypassPrefix .. command))

  return DRL_RET_SUCCESS
end -- dbot.execute.queue.bypass


function dbot.execute.queue.dequeueCR()
  local retval = DRL_RET_SUCCESS

  while (#dbot.execute.table > 0) do
    local charState = dbot.gmcp.getState()

    -- Get the next command (or array of commands) from the queue
    local commandEntry = dbot.execute.queue.pop()
    if (commandEntry == nil) then
      dbot.warn("dbot.execute.queue.dequeueCR: Popped a nil entry off of a non-empty queue")
      break
    end -- if

    -- Creating a string that concatenates all of the commands is helpful for debugging and notifications
    local commandString = dbot.execute.queue.getCommandString(commandEntry.commands)

    -- If we have a "fast" command, send it directly to the mud.  Easy peasy.
    if (commandEntry.commandType == drlDbotExecuteTypeFast) then
      if (commandEntry.commands ~= nil) then
        for _, command in ipairs(commandEntry.commands) do
          dbot.debug("Executing queued fast command \"@G" .. command .. "@W\"")
          retval = dbot.execute.queue.bypass(command)
        end -- for
      end -- if

    elseif (commandEntry.commandType == drlDbotExecuteTypeSafe) then

      -- If we are in the running state, wait for a while until we get out of that state.
      -- The char can't run forever :)  We could also wait if we are in another state that
      -- prevents us from executing, but the odds of someone coming out of AFK or sleeping
      -- at just the right moment are low.  We know that a run will end relatively soon so
      -- we handle that case a little differently to reduce the odds of aborting a request.
      local totTime = 0
      local timeout = 20
      while (totTime < timeout) do
        charState = dbot.gmcp.getState()
        if (charState ~= dbot.stateRunning) then
          break
        end -- if

        wait.time(drlSpinnerPeriodDefault)
        totTime = totTime + drlSpinnerPeriodDefault
      end -- while

      -- We can only run safe execution commands when we are either active or in combat
      --
      -- If a safe execution command cannot run because the user is too busy or if the user
      -- is in the wrong state (AFK, sleeping, note, etc.) we let the caller know via the
      -- callback parameter's return value field.  It is up to the caller to resubmit the 
      -- request if they really want it to run.  We do not try to re-queue the request here.
      -- Yes, we could re-queue the request and set a timer to attempt to run it later, but
      -- that's a lot of complexity for low odds of success.  If the user really is AFK or
      -- sleeping, the calling function will almost certainly time out before the state is
      -- what we need so we make it our policy to leave everything in the caller's hands.
      if (charState ~= dbot.stateActive) and (charState ~= dbot.stateCombat) then
        dbot.note("Skipping queued safe commands: \"@G" .. commandString .. "@W\": you are in state \"@C" ..
                  dbot.gmcp.getStateString(charState) .. "@W\"")
        retval = DRL_RET_NOT_ACTIVE

      elseif dbot.execute.quitIsPending then
        dbot.note("Skipping queued safe commands: \"@G" .. commandString .. 
                  "@W\": a request to quit is pending on the mud server")
        retval = DRL_RET_UNINITIALIZED

      elseif dbot.execute.afkIsPending then
        dbot.note("Skipping queued safe commands: \"@G" .. commandString .. 
                  "@W\": a request to go AFK is pending on the mud server")
        retval = DRL_RET_NOT_ACTIVE

      elseif dbot.execute.noteIsPending then
        dbot.note("Skipping queued safe commands: \"@G" .. commandString .. 
                  "@W\": a request to start a note is pending on the mud server")
        retval = DRL_RET_NOT_ACTIVE

      else
        retval = dbot.execute.queue.fence()
        if (retval ~= DRL_RET_SUCCESS) then
          dbot.debug("dbot.execute.queue.dequeueCR: Failed to execute prefix fence: " ..
                    dbot.retval.getString(retval))
        else
          if (commandEntry.setupFn ~= nil) then
            commandEntry.setupFn(commandEntry.setupData)
          end -- if

          dbot.prompt.hide()

          if (commandEntry.commands ~= nil) then
            for _, command in ipairs(commandEntry.commands) do
              dbot.debug("Executing queued safe command \"@G" .. command .. "@W\"")
              dbot.execute.queue.bypass(command)
            end -- for
          else
            dbot.warn("dbot.execute.queue.dequeueCR: commands array is nil!!!")
          end -- if

          retval = dbot.execute.queue.fence()
          if (retval ~= DRL_RET_SUCCESS) then
            dbot.warn("dbot.execute.queue.dequeueCR: Failed to execute suffix fence: " ..
                      dbot.retval.getString(retval))
          end -- if

          dbot.prompt.show()
        end -- if
      end -- if

    else
      dbot.warn("dbot.execute.queue.dequeueCR: invalid commandType field \"@R" ..
                (commandEntry.commandType or "nil") .. "@W\"")
      retval = DRL_RET_INTERNAL_ERROR
    end -- if

    if (commandEntry.resultFn ~= nil) then
      commandEntry.resultFn(commandEntry.resultData, retval)
    end -- if

  end -- while

  dbot.execute.queue.isDequeueRunning = false
  dbot.execute.queue.disable()

end -- dbot.execute.queue.dequeueCR


-- Build up a command string containing all commands in the command array delimited by semicolons.
-- This is useful for notification messages and debugging.
function dbot.execute.queue.getCommandString(commandArray)
  local commandString = ""

  if (commandArray ~= nil) and (#commandArray > 0) then
    for _, command in ipairs(commandArray) do
      if (command ~= "") then
        if (commandString == nil) or (commandString == "") then
          commandString = command
        else
          commandString = commandString .. "; " .. command
        end -- if
      end -- if
    end -- for
  end -- if

  return commandString
end -- dbot.execute.queue.getCommandString


function dbot.execute.new()
  if (not inv.inSafeMode) then
    return {}
  end -- if

  return nil
end -- dbot.execute.newCommands


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
  if (resultData ~= nil) then
    if (retval ~= nil) then
      dbot.callback.setReturn(resultData, retval)
    end -- if

    resultData.isDone = true
  end -- if
end -- dbot.callback.default


function dbot.callback.wait(resultData, timeout, period)
  local retval = DRL_RET_SUCCESS
  local totTime = 0

  if (resultData == nil) then
    dbot.warn("dbot.callback.wait: missing callback parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  timeout = tonumber(timeout or "")
  if (timeout == nil) then
    dbot.warn("dbot.callback.wait: missing timeout parameter")
    return DRL_RET_INVALID_PARAM
  end -- if

  -- The period is optional.  If it isn't provided, use the default value.
  if (period == nil) then
    period = drlSpinnerPeriodDefault
  end -- if

  while (dbot.callback.isDone(resultData) == false) do
    if (totTime > timeout) then
      dbot.debug("dbot.callback.wait: timed out waiting for a callback to complete")
      retval = DRL_RET_TIMEOUT
      break
    end -- if

    wait.time(period)
    totTime = totTime + period
  end -- while

  -- If there was a problem accessing the callback, return an error corresponding to the problem
  -- we hit.  Otherwise, return the return value for the operation executed by the callback.
  if (retval ~= DRL_RET_SUCCESS) then
    return retval
  else
    return dbot.callback.getReturn(resultData)
  end -- if
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

  wait.make(dbot.remote.getCR)

  local timeout = 10
  local totTime = 0
  while (dbot.remote.getPkg.isDone == false) do
    if (totTime > timeout) then
      retval = DRL_RET_TIMEOUT
      break
    end -- if

    wait.time(drlSpinnerPeriodDefault)
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

  local urlThread = async.request(dbot.remote.getPkg.url, dbot.remote.getPkg.protocol)

  if (urlThread == nil) then
    dbot.warn("dbot.remote.getCR: Failed to create thread requesting remote data")
    retval = DRL_RET_INTERNAL_ERROR

  else
    local timeout = 10
    local totTime = 0
    while (urlThread:alive()) do
      if (totTime > timeout) then
        retval = DRL_RET_TIMEOUT
        break
      end -- if

      wait.time(drlSpinnerPeriodDefault)
      totTime = totTime + drlSpinnerPeriodDefault
    end -- while

    local remoteRet, page, status, headers, fullStatus = urlThread:join()

    if (status ~= 200) then
      dbot.warn("dbot.remote.getCR: Failed to retrieve remote file")
      retval = DRL_RET_INTERNAL_ERROR
    else
      dbot.remote.getPkg.fileData = page
    end -- if

    dbot.remote.getPkg.isDone = true

  end -- if

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

  wait.make(dbot.version.changelog.getCR)

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

  wait.make(dbot.version.update.releaseCR)

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


