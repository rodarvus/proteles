import Foundation

/// The MUSHclient `utils` global library, provided to every plugin by the
/// compat shim. MUSHclient exposes a large `utils.*` surface (split, hex,
/// base64, timers, file/dir access, and a pile of native GUI dialogs). We
/// implement the pure-computation helpers properly, back the two filesystem
/// helpers with sandbox-scoped host primitives, and provide safe stubs for the
/// GUI/native pieces (which have no headless meaning) so plugins that call them
/// *load and run* rather than erroring on a nil global.
///
/// This is shared infrastructure — dinv needs `readdir`/`shellexecute`/`split`,
/// but `timer`/`tohex`/`base64`/the dialog stubs are used across the corpus
/// (the Aardwolf package, mappers, etc.), so they live here once for all.
extension LuaRuntime {
    nonisolated static let utilsShimSource = #"""
    utils = utils or {}

    -- Timing -------------------------------------------------------------------
    -- High-resolution wall-clock seconds (sub-second). Plugins use it to
    -- throttle redraws/animations: `if utils.timer() - last > interval`.
    function utils.timer() return proteles.monotonic() end

    -- String helpers -----------------------------------------------------------
    -- split(s, sep): split on the literal separator `sep` (default ","),
    -- returning an array of pieces. sep == "" splits into characters.
    function utils.split(s, sep)
      s = tostring(s == nil and "" or s)
      sep = sep == nil and "," or tostring(sep)
      local out = {}
      if sep == "" then
        for ch in s:gmatch(".") do out[#out + 1] = ch end
        return out
      end
      local pos = 1
      while true do
        local i = string.find(s, sep, pos, true)
        if not i then out[#out + 1] = string.sub(s, pos); break end
        out[#out + 1] = string.sub(s, pos, i - 1)
        pos = i + #sep
      end
      return out
    end

    -- Lowercase hex of the raw bytes, and its inverse.
    function utils.tohex(s)
      return (tostring(s == nil and "" or s):gsub(".", function(c)
        return string.format("%02x", string.byte(c))
      end))
    end
    function utils.fromhex(s)
      return (tostring(s == nil and "" or s):gsub("%x%x", function(h)
        return string.char(tonumber(h, 16))
      end))
    end

    -- Base64 (standard alphabet) — the proven arithmetic-only implementation
    -- (lua-users.org/wiki/BaseSixtyFour), since Lua 5.1 has no bitwise ops.
    local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    function utils.base64encode(data)
      data = tostring(data == nil and "" or data)
      return ((data:gsub(".", function(x)
        local r, b = "", x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
      end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return B64:sub(c + 1, c + 1)
      end) .. ({ "", "==", "=" })[#data % 3 + 1])
    end
    function utils.base64decode(data)
      data = tostring(data == nil and "" or data):gsub("[^" .. B64 .. "=]", "")
      return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", B64:find(x, 1, true) - 1
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
      end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return string.char(c)
      end))
    end

    -- Levenshtein edit distance (used for fuzzy matching across the corpus).
    function utils.edit_distance(a, b)
      a, b = tostring(a == nil and "" or a), tostring(b == nil and "" or b)
      local la, lb = #a, #b
      if la == 0 then return lb end
      if lb == 0 then return la end
      local prev = {}
      for j = 0, lb do prev[j] = j end
      for i = 1, la do
        local cur = { [0] = i }
        local ac = string.byte(a, i)
        for j = 1, lb do
          local cost = (ac == string.byte(b, j)) and 0 or 1
          cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        end
        prev = cur
      end
      return prev[lb]
    end
    utils.editdistance = utils.edit_distance

    -- Filesystem (sandbox-scoped host primitives) ------------------------------
    -- readdir(path): MUSHclient returns a table of directory entries (or nil).
    -- Plugins use it mostly as an existence check (dbot.fileExists), so we
    -- return an empty table when the path exists and nil when it doesn't.
    function utils.readdir(path)
      if proteles.fileExists(tostring(path == nil and "" or path)) then return {} end
      return nil
    end
    -- shellexecute: we never spawn a shell. The one supported use is directory
    -- creation (dinv runs `cmd /C mkdir "<dir>"` for its state dir); extract the
    -- path and create it natively (sandbox-scoped). Anything else is a safe
    -- no-op success.
    function utils.shellexecute(operation, file, params, directory, show)
      local cmd = tostring(file == nil and "" or file) .. " " .. tostring(params == nil and "" or params)
      local path = cmd:match('mkdir%s+"(.-)"') or cmd:match("mkdir%s+(%S+)")
      if path then return proteles.makeDirectory(path) end
      return true
    end

    -- Native dialogs (msgbox/inputbox/editbox/choose/file pickers) → the app's
    -- modal provider via proteles.dialog; with no provider they degrade safely
    -- (cancelled / "ok"). msgbox(message, title, buttons): buttons is the
    -- MUSHclient code (0=OK, 1=OK/Cancel, 3=Yes/No/Cancel, 4=Yes/No).
    function utils.msgbox(message, title, buttons)
      return proteles.dialog("msgbox", tostring(message == nil and "" or message),
        tostring(title == nil and "" or title), tonumber(buttons) or 0)
    end
    utils.umsgbox = utils.msgbox
    -- inputbox(message, title, default) → entered text or nil.
    function utils.inputbox(message, title, default)
      return proteles.dialog("input", tostring(message == nil and "" or message),
        tostring(title == nil and "" or title), tostring(default == nil and "" or default), false)
    end
    -- editbox(title, prompt, default) → multi-line text or nil.
    function utils.editbox(title, prompt, default)
      return proteles.dialog("input", tostring(prompt == nil and "" or prompt),
        tostring(title == nil and "" or title), tostring(default == nil and "" or default), true)
    end
    -- choose(message, title, items[, default]) → the 1-based index of the pick,
    -- or nil if cancelled.
    function utils.choose(message, title, items)
      if type(items) ~= "table" then return nil end
      return proteles.dialog("choose", tostring(message == nil and "" or message),
        tostring(title == nil and "" or title), unpack(items))
    end
    function utils.filepicker() return proteles.dialog("openfile", "Choose a file", false) end
    function utils.directorypicker() return proteles.dialog("openfile", "Choose a folder", true) end

    -- Remaining native dialogs we don't (yet) implement: safe no-op stubs so
    -- plugins that offer them still load and their non-dialog paths work.
    local function nilFn() return nil end
    for _, name in ipairs({
      "listbox", "multilistbox", "fontpicker", "filterpicker", "colourpicker",
      "spellcheckdialog", "xmlread", "functionlist", "callbackslist",
    }) do utils[name] = nilFn end
    function utils.getfontfamilies() return {} end
    function utils.getfontsize(...) return 0 end
    function utils.appendtonotepad(title, message, replace)
      message = tostring(message == nil and "" or message):gsub("\n", "\r\n")
      if replace then return ReplaceNotepad(title, message) end
      return AppendToNotepad(title, message)
    end
    function utils.sendtonotepad(title, message)
      return SendToNotepad(title, tostring(message == nil and "" or message):gsub("\n", "\r\n"))
    end
    function utils.activatenotepad(title) return ActivateNotepad(title) end
    function utils.sendtofront(...) return 0 end
    function utils.reload_global_prefs(...) return 0 end

    -- Heavy/native helpers we don't (yet) implement: degrade safely so callers
    -- don't crash on a nil concat. `metaphone` returns the input; compression is
    -- identity; a non-cryptographic deterministic hash backs hash/md5/sha.
    function utils.metaphone(s) return tostring(s == nil and "" or s) end
    function utils.compress(s) return s end
    function utils.decompress(s) return s end
    -- Deterministic, non-cryptographic digest (djb2 — Lua 5.1 has no bitops);
    -- enough to keep hash/md5/sha callers returning a stable hex string.
    function utils.hash(s)
      s = tostring(s == nil and "" or s)
      local h = 5381
      for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 4294967296 end
      return string.format("%08x", h)
    end
    utils.md5 = utils.hash
    utils.sha256 = utils.hash
    """#
}
