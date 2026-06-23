import Foundation

extension LuaRuntime {
    nonisolated static let compatShimOutputSource = """
    -- Output ----------------------------------------------------------------
    local proteles = proteles
    -- Tell/ColourTell APPEND coloured segments to `__pending`; Note/ColourNote/
    -- AnsiNote/print FLUSH them as one line, so a ColourTell row keeps colours.
    local __pending = {}
    local __note_style = 0
    local function __maskNoteStyle(style)
      style = math.floor(tonumber(style) or 0)
      local out = 0
      for _, bit in ipairs({1, 2, 4, 8, 32}) do
        if style % (bit * 2) >= bit then out = out + bit end
      end
      return out
    end
    -- Flush `__pending` + `extra` ({fg,bg,text,style} array) as one colourNote line.
    local function __flush(extra)
      local segs = __pending; __pending = {}
      if extra then for i = 1, #extra do segs[#segs + 1] = extra[i] end end
      local styled = false
      for i = 1, #segs do if (segs[i][4] or 0) ~= 0 then styled = true; break end end
      local flat, k = {}, 0
      if styled then
        for i = 1, #segs do
          flat[k+1], flat[k+2] = segs[i][1], segs[i][2]
          flat[k+3], flat[k+4] = segs[i][3], segs[i][4] or 0
          k = k + 4
        end
        proteles.styledColourNote(unpack(flat, 1, k))
      else
        for i = 1, #segs do
          flat[k+1], flat[k+2], flat[k+3] = segs[i][1], segs[i][2], segs[i][3]
          k = k + 3
        end
        proteles.colourNote(unpack(flat, 1, k))
      end
    end
    function __proteles_flush_pending()
      if #__pending > 0 then __flush(nil) end
    end
    -- Append one coloured cell, honouring embedded newlines: a newline in the
    -- text COMPLETES the current line and starts a fresh one, matching MUSHclient.
    local function __appendCell(fore, back, text)
      fore = fore == nil and "" or tostring(fore)
      back = back == nil and "" or tostring(back)
      text = text == nil and "" or tostring(text)
      local start = 1
      while true do
        local nl = text:find("\\n", start, true)
        if not nl then
          local rest = text:sub(start)
          if rest ~= "" then __pending[#__pending + 1] = { fore, back, rest, __note_style } end
          return
        end
        local chunk = text:sub(start, nl - 1)
        if chunk ~= "" then __pending[#__pending + 1] = { fore, back, chunk, __note_style } end
        __flush()
        start = nl + 1
      end
    end
    function Tell(text) __appendCell("", "", text) end
    function ColourTell(...)
      local a, n = {...}, select("#", ...)
      for b = 1, n, 3 do __appendCell(a[b], a[b + 1], a[b + 2]) end
    end
    function Note(text)
      text = text == nil and "" or tostring(text)
      if #__pending == 0 and __note_style == 0 then proteles.echo(text)
      else __flush({ { "", "", text, __note_style } }) end
    end
    function ColourNote(...)
      local a, n = {...}, select("#", ...)
      local extra = {}
      for b = 1, n, 3 do
        extra[#extra + 1] = {
          a[b]     == nil and "" or tostring(a[b]),
          a[b + 1] == nil and "" or tostring(a[b + 1]),
          a[b + 2] == nil and "" or tostring(a[b + 2]),
          __note_style,
        }
      end
      __flush(extra)
    end
    function NoteStyle(style) __note_style = __maskNoteStyle(style); return error_code.eOK end
    function GetNoteStyle() return __note_style end
    -- Render ANSI-SGR text in colour. A pending tag prefix is flattened to its
    -- text because a coloured prefix and ANSI body cannot share one effect.
    function AnsiNote(text)
      local prefix = ""
      for i = 1, #__pending do prefix = prefix .. __pending[i][3] end
      __pending = {}
      proteles.echoAnsi(prefix .. (text == nil and "" or tostring(text)))
    end
    """
}
