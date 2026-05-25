----------------------------------------------------------------------------------------------------
-- Module to track which tags are enabled
--
-- Tags add opening and terminating strings to the output.  They surround a particular operation
-- so that the user can know when the operation starts, when it stops, and what the final return
-- value of the operation is.
--
-- inv.tags.init.atActive()
-- inv.tags.fini(doSaveState)
--
-- inv.tags.save()
-- inv.tags.load()
-- inv.tags.reset()
--
-- inv.tags.enable()
-- inv.tags.disable()
-- inv.tags.isEnabled()
--
-- inv.tags.display()
-- inv.tags.set(tagNames, tagValue)
--
-- inv.tags.start(moduleName, startTag)
-- inv.tags.stop(moduleName, endTag, returnValue)
--
-- inv.tags.new(tagMsg, infoMsg, setupFn, cleanupFn)
--
-- inv.tags.cleanup.timed(tag, retval)
-- inv.tags.cleanup.info(tag, retval)
----------------------------------------------------------------------------------------------------

inv.tags           = {}
inv.tags.init      = {}
inv.tags.table     = {}
inv.tags.cleanup   = {}

invTagsRefresh   = "refresh"
invTagsBuild     = "build"
invTagsSearch    = "search" 
invTagsGet       = "get"
invTagsPut       = "put"
invTagsStore     = "store"
invTagsKeyword   = "keyword"
invTagsOrganize  = "organize"
invTagsSet       = "set"
invTagsSnapshot  = "snapshot"
invTagsPriority  = "priority"
invTagsAnalyze   = "analyze"
invTagsUsage     = "usage"
invTagsUnused    = "unused"
invTagsCompare   = "compare"
invTagsCovet     = "covet"
invTagsBackup    = "backup"
invTagsReset     = "reset"
invTagsForget    = "forget"
invTagsNotify    = "notify"
invTagsCache     = "cache"
invTagsVersion   = "version"
invTagsHelp      = "help"
invTagsMigrate   = "migrate"

inv.tags.modules = invTagsBuild     .. " " ..
                   invTagsRefresh   .. " " ..
                   invTagsSearch    .. " " ..
                   invTagsGet       .. " " ..
                   invTagsPut       .. " " ..
                   invTagsStore     .. " " ..
                   invTagsKeyword   .. " " ..
                   invTagsOrganize  .. " " ..
                   invTagsSet       .. " " ..
                   invTagsSnapshot  .. " " ..
                   invTagsPriority  .. " " ..
                   invTagsAnalyze   .. " " ..
                   invTagsUsage     .. " " ..
                   invTagsUnused    .. " " ..
                   invTagsCompare   .. " " ..
                   invTagsCovet     .. " " ..
                   invTagsBackup    .. " " ..
                   invTagsReset     .. " " ..
                   invTagsForget    .. " " ..
                   invTagsNotify    .. " " ..
                   invTagsCache     .. " " ..
                   invTagsVersion   .. " " ..
                   invTagsHelp


drlInvTagOn      = "on"
drlInvTagOff     = "off"


function inv.tags.init.atActive()
  local retval = DRL_RET_SUCCESS

  -- Pull in what we already know
  retval = inv.tags.load()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.tags.init.atActive: Failed to load tags data: " .. dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.tags.init.atActive


function inv.tags.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  if (doSaveState) then
    -- Save our current tags data
    retval = inv.tags.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.tags.fini: Failed to save tags data: " .. dbot.retval.getString(retval))
    end -- if
  end -- if

  return retval
end -- inv.tags.fini


function inv.tags.save()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  if not inv.tags.table then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM config WHERE key LIKE 'tag.%'")

    for tagName, tagValue in pairs(inv.tags.table) do
      local query = string.format("INSERT INTO config (key, value) VALUES (%s, %s)",
                                  dinv_db.fixsql("tag." .. tagName), dinv_db.fixsql(tagValue))
      db:exec(query)
      if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
        dbot.warn("inv.tags.save: Failed to save tag " .. tagName)
        return DRL_RET_INTERNAL_ERROR
      end
    end

    return DRL_RET_SUCCESS
  end)
end -- inv.tags.save


function inv.tags.load()
  local db = dinv_db.handle
  if not db then
    inv.tags.reset()
    return DRL_RET_SUCCESS
  end

  -- Check if any tag rows exist
  local count = 0
  for row in db:nrows("SELECT COUNT(*) as cnt FROM config WHERE key LIKE 'tag.%'") do
    count = row.cnt
  end

  if count == 0 then
    inv.tags.reset()
    return DRL_RET_SUCCESS
  end

  inv.tags.table = {}
  for row in db:nrows("SELECT key, value FROM config WHERE key LIKE 'tag.%'") do
    local tagName = row.key:sub(5)  -- strip "tag." prefix
    inv.tags.table[tagName] = row.value
  end

  return DRL_RET_SUCCESS
end -- inv.tags.load


function inv.tags.reset()
  inv.tags.table = {}

  for tag in inv.tags.modules:gmatch("%S+") do
    inv.tags.table[tag] = drlInvTagOff
  end -- for

  -- This is a top-level flag enabling or disabling all other tags
  inv.tags.table["tags"] = drlInvTagOn

  local retval = inv.tags.save()
  if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("inv.tags.reset: Failed to save tags persistent data: " .. dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.tags.reset


function inv.tags.enable()
  inv.tags.table["tags"] = drlInvTagOn
  dbot.info("Tags module is @GENABLED@W (specific tags may or may not be enabled)")
  return inv.tags.save()
end -- inv.tags.enable


function inv.tags.disable()
  inv.tags.table["tags"] = drlInvTagOff
  dbot.info("Tags module is @RDISABLED@W (individual tag status is ignored when the module is disabled)")
  return inv.tags.save()
end -- inv.tags.disable


function inv.tags.isEnabled()
  if (inv.tags.table ~= nil) and (inv.tags.table["tags"] ~= nil) and
     (inv.tags.table["tags"] == drlInvTagOn) then
    return true
  else
    return false
  end -- if
end -- inv.tags.isEnabled


function inv.tags.display()
  local retval = DRL_RET_SUCCESS
  local isEnabled

  if inv.tags.isEnabled() then
    isEnabled = "@GENABLED@W"
  else
    isEnabled = "@RDISABLED@W"
  end -- if

  dbot.print("@y" .. pluginNameAbbr .. "@W : tags are " .. isEnabled)
  dbot.print("@WSupported tags")

  for tag in inv.tags.modules:gmatch("%S+") do
    local tagValue = inv.tags.table[tag] or "uninitialized"
    local valuePrefix

    if (tagValue == drlInvTagOn) then
      valuePrefix = "@G"
    else
      valuePrefix = "@R"
    end -- if

    dbot.print(string.format("@C  %10s@W = ", tag) .. valuePrefix .. tagValue)
  end -- for

  return retval
end -- inv.tags.display


function inv.tags.set(tagNames, tagValue)
  local retval = DRL_RET_SUCCESS

  if (tagValue ~= drlInvTagOn) and (tagValue ~= drlInvTagOff) then
    dbot.warn("inv.tags.set: Invalid tag value \"" .. (tagValue or "nil") .. "\"")
    return DRL_RET_INVALID_PARAM
  end -- if

  for tag in tagNames:gmatch("%S+") do
    if dbot.isWordInString(tag, inv.tags.modules) then
      inv.tags.table[tag] = tagValue

      local valuePrefix
      if (tagValue == drlInvTagOn) then
        valuePrefix = "@G"
      else
        valuePrefix = "@R"
      end -- if

      dbot.note("Set tag \"@C" .. tag .. "@W\" to \"" .. valuePrefix .. tagValue .. "@W\"")
    else
      dbot.warn("inv.tags.set: Failed to set tag \"@C" .. tag .. "@W\": Unsupported tag")
      retval = DRL_RET_INVALID_PARAM
    end -- if
  end -- for

  local saveRetval = inv.tags.save()
  if (saveRetval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
    dbot.warn("inv.tags.set: Failed to save tags persistent data: " .. dbot.retval.getString(saveRetval))
  end -- if

  -- If the only problem that arose was with the save, return the save's return value.  Otherwise,
  -- return whatever return value we hit while setting the tags.
  if (retval == DRL_RET_SUCCESS) and (saveRetval ~= DRL_RET_SUCCESS) then
    return saveRetval
  else
    return retval
  end -- if
end -- inv.tags.set


function inv.tags.stop(moduleName, endTag, retval)
  if (retval == nil) then
    retval = DRL_RET_INTERNAL_ERROR
  end -- if

  if (endTag == nil) then
    return retval
  end -- if

  -- Run the end tag's cleanup callback function (if one exists).  Otherwise run the default
  -- cleanup callback function.
  if (endTag.cleanupFn ~= nil) then
    endTag.cleanupFn(endTag, retval)
  else
    inv.tags.cleanup.info(endTag, retval)
  end -- if

  -- Output the end tag's message if the specified module tag is enabled
  if (moduleName ~= nil) and (endTag.tagMsg ~= nil) and (endTag.tagMsg ~= "") and 
     (inv.tags.table ~= nil) and (inv.tags.table[moduleName] == drlInvTagOn) and
     inv.tags.isEnabled() then
    local tagMsg = "{/" .. endTag.tagMsg .. ":" .. dbot.getTime() - endTag.startTime .. ":" .. retval .. 
                   ":" .. dbot.retval.getString(retval) .. "}"
    local charState = dbot.gmcp.getState()

    -- If we are in a state that allows echo'ing messages, send the end tag.  Otherwise, warn the
    -- user.
    if (charState == dbot.stateActive)   or
       (charState == dbot.stateCombat)   or
       (charState == dbot.stateSleeping) or
       (charState == dbot.stateTBD)      or
       (charState == dbot.stateResting)  or
       (charState == dbot.stateRunning)  then
      dbot.execute.fast.command("echo " .. tagMsg)
    else
      dbot.warn("You are in state \"@C" .. dbot.gmcp.getStateString(charState) ..
                "@W\": Could not echo end tag \"@G" .. tagMsg .. "@W\"")
    end -- if
  end -- if

  return retval
end -- inv.tags.end


function inv.tags.new(tagMsg, infoMsg, setupFn, cleanupFn)
  local newTag = {}

  newTag.tagMsg    = tagMsg or ""
  newTag.infoMsg   = infoMsg or ""
  newTag.cleanupFn = cleanupFn
  newTag.startTime = dbot.getTime()

  if (setupFn ~= nil) then
    setupFn(newTag)
  end -- if

  return newTag
end -- inv.tags.new


function inv.tags.cleanup.timed(tag, retval)
  if (tag == nil) or (retval == nil) then
    return
  end -- if

  -- If an info message is included in the end tag, merge it with the time.  Otherwise just
  -- print the execution time.
  local executionTime = dbot.getTime() - tag.startTime
  local minutes = math.floor(executionTime / 60)
  local seconds = executionTime - (minutes * 60)
  local timeString = ""

  if (minutes == 1) then
    timeString = minutes .. " minute, "
  elseif (minutes > 1) then
    timeString = minutes .. " minutes, "
  end -- if

  if (seconds == 1) then
    timeString = timeString .. seconds .. " second"
  else
    timeString = timeString .. seconds .. " seconds"
  end -- if

  if (tag.infoMsg ~= nil) and (tag.infoMsg ~= "") then
    dbot.info(tag.infoMsg .. " (@C" .. timeString .. "@W): " .. dbot.retval.getString(retval))
  else
    dbot.info("Total time for command: " .. timeString)
  end -- if

end -- inv.tags.cleanup.timed


function inv.tags.cleanup.info(tag, retval)
  if (tag == nil) or (retval == nil) then
    return
  end -- if

  -- Print the "info" message if one is included in the end tag
  if (tag.infoMsg ~= nil) and (tag.infoMsg ~= "") then
    dbot.info(tag.infoMsg .. ": " .. dbot.retval.getString(retval))
  end -- if

end -- inv.tags.cleanup.info


