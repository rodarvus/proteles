----------------------------------------------------------------------------------------------------
-- inv.report : report item and set summaries to a channel
--
-- Functions:
--  inv.report.item(channel, name)
--  inv.report.itemCR()
--
----------------------------------------------------------------------------------------------------

inv.report = {}

inv.report.itemPkg = nil
function inv.report.item(channel, name)

  if (channel == nil) or (channel == "") then
    dbot.warn("inv.report.item: Missing channel name")
    return DRL_RET_INVALID_PARAM
  end -- if

  if (name == nil) or (name == "") then
    dbot.warn("inv.report.item: Missing relative name of item to report")
    return DRL_RET_INVALID_PARAM
  end -- if

  inv.report.itemPkg         = {}
  inv.report.itemPkg.channel = channel
  inv.report.itemPkg.name    = name

  wait.make(inv.report.itemCR)

  return DRL_RET_SUCCESS

end -- inv.report.item


function inv.report.itemCR()
  local retval = DRL_RET_SUCCESS

  if (inv.report.itemPkg == nil) then
    dbot.warn("inv.report.itemCR: package is nil!?!?")
    return DRL_RET_INTERNAL_ERROR
  end -- if

  local channel = inv.report.itemPkg.channel
  local name    = inv.report.itemPkg.name
  local idArray

  if (channel == nil) or (channel == "") then
    dbot.warn("inv.report.itemCR: missing channel parameter")
    retval = DRL_RET_INVALID_PARAM
  end -- if

  if (name == nil) or (name == "") then
    dbot.warn("inv.report.itemCR: missing name parameter")
    retval = DRL_RET_INVALID_PARAM
  end -- if

  if (retval == DRL_RET_SUCCESS) then
    dbot.debug("inv.report.itemCR: channel=\"" .. channel .. "\", name=\"" .. name .. "\"")

    -- If the name is a number, search for an item whose objId matches the number.  Otherwise,
    -- assume it is a relative name.
    local objId = tonumber(name)
    if (objId ~= nil) then
      idArray, retval = inv.items.searchCR("id " .. objId, true)
    else
      idArray, retval = inv.items.searchCR("rname " .. name, true)
    end -- if

    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.report.itemCR: failed to search inventory table: " .. dbot.retval.getString(retval))

    elseif (#idArray == 0) then
      dbot.warn("inv.report.itemCR: No items matched name \"" .. name .. "\"")
      retval = DRL_RET_MISSING_ENTRY

    elseif (#idArray > 1) then
      dbot.warn("inv.report.itemCR: More than one item matched name \"" .. name .. "\"")
      retval = DRL_RET_INTERNAL_ERROR

    else
      objId = idArray[1]
      inv.items.displayItem(objId, invDisplayVerbosityBasic, nil, channel)

    end -- if
    
  end -- if

  inv.report.itemPkg = nil
  return retval

end -- inv.report.itemCR

