extension LuaRuntime {
    /// Reference-compatible `storeFromOutside`: accepts Aard-coded text or a
    /// serialized styles table plus tab, timestamp, log, and link metadata.
    nonisolated static let chatCaptureShimSource = #"""
    function __proteles_store_from_outside(argc, ...)
      local args = {...}
      local text = args[1] or ""
      local ok, styles = false, nil
      if type(text) == "string" and string.match(text, "^%s*{") then
        ok, styles = pcall(function() return loadstring("return "..text)() end)
      end
      if ok and type(styles) == "table" then
        local lines = {}
        if type(styles[1]) == "table" and styles[1].text == nil then
          for _, line_styles in ipairs(styles) do
            table.insert(lines, StylesToColours(line_styles))
          end
        else
          table.insert(lines, StylesToColours(styles))
        end
        text = table.concat(lines, "\n")
      end
      local tab = ""
      if type(args[2]) == "string" then
        tab = args[2]
      elseif type(args[2]) == "number" then
        tab = "Tab "..tostring(args[2])
      end
      local links_json = nil
      if args[5] then
        local links_ok, links = pcall(function()
          return loadstring("return "..args[5])()
        end)
        if links_ok then links_json = proteles.jsonEncode(links) end
      end
      if argc <= 2 then
        proteles.chatCapture(text, tab)
      else
        proteles.chatCapture(text, tab, args[3] ~= false, args[4] == true, links_json)
      end
      return true
    end
    """#
}
