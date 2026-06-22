import CLua
import Foundation

/// D2 — the `rex` (lrexlib/PCRE) Lua module, implemented over Proteles' existing
/// ICU regex (`PatternMatcher`), which already bridges PCRE named captures
/// (`(?P<name>…)` / `(?<name>…)`). Plugins `require "rex"`, then
/// `rex.new(pattern):match(subject [, init])` with numbered + named captures.
///
/// `:match` mirrors lrexlib's contract — `start, end, captures = re:match(subj)`
/// — with 1-based start/end and a captures table holding numbered subpatterns
/// (1..n) plus named-subpattern string keys. `rex.new` compile-validates so a
/// bad/PCRE-only pattern raises (pcall-guarded callers like findtrigger then
/// degrade gracefully) rather than silently never matching.
extension LuaRuntime {
    /// The `rex` module source (returned from `require "rex"`).
    nonisolated static let rexModuleSource = #"""
    local rex = {}
    local meta = {}
    meta.__index = meta
    -- rex.new(pattern): compile-validate up front (lrexlib raises on a bad
    -- pattern; pcall-guarded callers rely on that).
    function rex.new(pattern)
      pattern = tostring(pattern)
      if not proteles.regexValid(pattern) then
        error("rex.new: pattern not supported: " .. pattern, 2)
      end
      return setmetatable({ pattern = pattern }, meta)
    end
    -- re:match(subject [, init]) -> start, end, captures  (nil if no match)
    function meta:match(subject, init)
      return proteles.regexMatch(self.pattern, tostring(subject), tonumber(init) or 1)
    end
    meta.exec = meta.match -- close enough for the corpus (offsets vs substrings unused)
    -- re:gmatch(subject) -> iterator yielding the captures of each match.
    function meta:gmatch(subject)
      subject = tostring(subject)
      local pos = 1
      return function()
        local s, e, caps = proteles.regexMatch(self.pattern, subject, pos)
        if not s then return nil end
        pos = (e >= s) and (e + 1) or (s + 1) -- always advance (empty-match guard)
        return caps
      end
    end
    -- Module-level convenience forms a few plugins use.
    function rex.match(subject, pattern, init)
      return proteles.regexMatch(tostring(pattern), tostring(subject), tonumber(init) or 1)
    end
    function rex.new_p(pattern) return rex.new(pattern) end
    return rex
    """#

    /// `proteles.regexValid(pattern)` / `proteles.regexMatch(pattern, subject,
    /// init)` — the host side of the `rex` module.
    nonisolated func regexValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        let pattern = Self.argString(arguments, 0)
        switch function {
        case .regexValid:
            return [.boolean(cachedRegex(for: pattern) != nil)]
        case .regexMatch:
            guard let matcher = cachedRegex(for: pattern) else { return [.nil] }
            let subject = Self.argString(arguments, 1)
            let initArg = Int(Self.argDouble(arguments, 2)) // 1-based; 0/absent → 1
            let fromUTF16 = Swift.max(0, (initArg <= 0 ? 1 : initArg) - 1)
            guard let match = matcher.match(subject, fromUTF16: fromUTF16),
                  let range = match.utf16Range
            else { return [.nil] }
            // lrexlib positions are 1-based; `end` is the last matched char.
            return [
                .number(Double(range.lowerBound + 1)),
                .number(Double(range.upperBound)),
                pushRegexCaptures(match)
            ]
        default:
            return [.nil]
        }
    }

    /// Compile (and cache) an ICU matcher for `pattern`; `nil` if ICU can't
    /// compile it (a PCRE-only construct), so `rex.new` can raise.
    private nonisolated func cachedRegex(for pattern: String) -> PatternMatcher? {
        if let cached = regexCache[pattern] { return cached }
        guard let matcher = try? PatternMatcher(pattern: .regex(pattern), caseSensitive: true)
        else { return nil }
        regexCache[pattern] = matcher
        return matcher
    }

    /// Build the lrexlib captures table: numbered subpatterns (1..n, dropping the
    /// whole-match at index 0) plus named-subpattern string keys. Returned via
    /// the registry-ref bridge (`LuaValue` has no table case), like `pushNameArray`.
    private nonisolated func pushRegexCaptures(_ match: TriggerMatch) -> LuaValue {
        let groupCount = Swift.max(0, match.captures.count - 1)
        lua_createtable(state, Int32(groupCount), Int32(match.named.count))
        if match.captures.count > 1 {
            for index in 1..<match.captures.count {
                lua_pushstring(state, match.captures[index])
                lua_rawseti(state, -2, Int32(index)) // table[i] = group i (1-based)
            }
        }
        for (name, value) in match.named {
            lua_pushstring(state, value)
            lua_setfield(state, -2, name)
        }
        let ref = luaL_ref(state, LUA_REGISTRYINDEX) // pops the table, stores it
        noteTransientRef(ref)
        return .functionRef(ref)
    }
}
