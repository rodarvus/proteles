----------------------------------------------------------------------------------------------------
--
-- Module to calculate how many bonuses are available to each stat due to equipment
--
-- There are limits to how many stat bonuses are applied due to equipment.  The limits vary based
-- on a character's level and the spell bonuses that are active for the character.  This module
-- checks the current stats and determines how many stats can be provided by equipment.
--
-- This is not an exact science.  The equipment bonuses can be very different for the same 
-- character at the same level if the character has a good spellup on one call and a poor spellup
-- on another call.  Our policy is to assume that the character has done their best to spellup
-- prior to wearing a set.  They can always re-wear a set to pick up the optimal available equipment
-- if a good (e.g., SH) spellup wears off.
--
-- This module remembers the current, max, and average values for each stat at each level.  This
-- helps make bonus estimates more accurate when we are creating a set for a different level than
-- the character currently has.
--
-- inv.statBonus.init.atInstall()
-- inv.statBonus.init.atActive()
-- inv.statBonus.fini(doSaveState)
--
-- inv.statBonus.save()
-- inv.statBonus.load()
-- inv.statBonus.reset()
--
-- inv.statBonus.estimate(level)
-- inv.statBonus.get(level, bonusType) -- types include current, ave, and max
-- inv.statBonus.set
-- inv.statBonus.setCR
-- inv.statBonus.setSetupFn()
--
-- inv.statBonus.timer.update
--
-- inv.statBonus.trigger.get
-- inv.statBonus.trigger.start
--
----------------------------------------------------------------------------------------------------

inv.statBonus              = {}
inv.statBonus.init         = {}
inv.statBonus.closingMsg   = "{ \\dinv inv.statBonus }"
inv.statBonus.currentBonus = { int = 0, luck = 0, wis = 0, str = 0, dex = 0, con = 0 }


function inv.statBonus.init.atInstall()
  local retval = DRL_RET_SUCCESS

  -- Trigger on a call to "stats" to determine how many stat bonuses currently are available to equipment
  check (AddTriggerEx(inv.statBonus.trigger.getName,
                     "^(.*)$",
                      "inv.statBonus.trigger.get(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11,
                      0, "", "", sendto.script, 0))
  check (EnableTrigger(inv.statBonus.trigger.getName, false)) -- default to off

  return retval
end -- inv.statBonus.init.atInstall


function inv.statBonus.init.atActive()
  local retval = DRL_RET_SUCCESS

  retval = inv.statBonus.load()
  if (retval ~= DRL_RET_SUCCESS) then
    dbot.warn("inv.statBonus.init.atActive: failed to load statBonus data from storage: " ..
              dbot.retval.getString(retval))
  end -- if

  return retval
end -- inv.statBonus.init.atActive


function inv.statBonus.fini(doSaveState)
  local retval = DRL_RET_SUCCESS

  dbot.deleteTrigger(inv.statBonus.trigger.getName)

  dbot.deleteTimer(inv.statBonus.timer.name)

  if (doSaveState) then
    -- Save our current data
    retval = inv.statBonus.save()
    if (retval ~= DRL_RET_SUCCESS) and (retval ~= DRL_RET_UNINITIALIZED) then
      dbot.warn("inv.statBonus.fini: Failed to save inv.statBonus module data: " ..
                dbot.retval.getString(retval))
    end -- if
  end -- if

  inv.statBonus.currentBonus = { int = 0, luck = 0, wis = 0, str = 0, dex = 0, con = 0 }

  return retval
end -- inv.statBonus.fini


function inv.statBonus.save()
  local db = dinv_db.handle
  if not db then return DRL_RET_UNINITIALIZED end

  return dinv_db.transaction(function()
    db:exec("DELETE FROM stat_bonuses")

    local stats = { "int", "wis", "luck", "str", "dex", "con" }

    -- Save spell bonuses (ave and max per level)
    if inv.statBonus.spellBonus then
      for level, data in pairs(inv.statBonus.spellBonus) do
        for _, stat in ipairs(stats) do
          local aveVal = (data.ave and data.ave[stat]) or nil
          local maxVal = (data.max and data.max[stat]) or nil
          if aveVal or maxVal then
            local query = string.format(
              "INSERT INTO stat_bonuses (bonus_type, level, stat_name, ave_val, max_val) VALUES ('spell', %d, %s, %s, %s)",
              level, dinv_db.fixsql(stat), dinv_db.fixnum(aveVal), dinv_db.fixnum(maxVal))
            db:exec(query)
            if dinv_db.dbcheck(db:errcode(), db:errmsg(), query) then
              dbot.warn("inv.statBonus.save: Failed to save spell bonus")
              return DRL_RET_INTERNAL_ERROR
            end
          end
        end
      end
    end

    -- equipBonus is intentionally NOT persisted.  It is a deterministic per-
    -- session cache of levelBonus minus spellBonus (with clamping) and is
    -- recomputed inside inv.statBonus.get on demand.  Persisting it would
    -- carry forward equipBonus rows derived from old estimate-seeded
    -- spellBonus values; dropping the column from save() also lets the
    -- DELETE FROM above clean up any legacy 'equip' rows from earlier
    -- versions on first save.

    return DRL_RET_SUCCESS
  end)
end -- inv.statBonus.save


function inv.statBonus.load()
  local db = dinv_db.handle
  if not db then
    inv.statBonus.reset()
  else
    -- Check if any stat bonus rows exist
    local count = 0
    for row in db:nrows("SELECT COUNT(*) as cnt FROM stat_bonuses") do
      count = row.cnt
    end

    if count == 0 then
      inv.statBonus.spellBonus = {}
      inv.statBonus.equipBonus = {}
    else
      -- Load spell bonuses
      inv.statBonus.spellBonus = {}
      for row in db:nrows("SELECT level, stat_name, ave_val, max_val FROM stat_bonuses WHERE bonus_type = 'spell'") do
        local level = row.level
        if not inv.statBonus.spellBonus[level] then
          inv.statBonus.spellBonus[level] = { ave = {}, max = {} }
        end
        if row.ave_val then inv.statBonus.spellBonus[level].ave[row.stat_name] = row.ave_val end
        if row.max_val then inv.statBonus.spellBonus[level].max[row.stat_name] = row.max_val end
      end

      -- equipBonus is a per-session derived cache populated lazily by
      -- inv.statBonus.get; we don't load any 'equip' rows from disk (they
      -- are stale derivatives of past estimate-seeded spellBonus values and
      -- the next inv.statBonus.save will drop them when it does the DELETE
      -- FROM stat_bonuses up front).  Start empty.
      inv.statBonus.equipBonus = {}
    end
  end

  -- Kick off a timer to continually update the bonuses.  Ideally, we would just call the
  -- inv.statBonus.timer.update() function here.  Unfortunately, that function relies on mushclient
  -- components that may not be available when we load right at the start.  Instead, we simply
  -- kick off the timer manually and then let it self-perpetuate once it is going.
  check (AddTimer(inv.statBonus.timer.name, 0, inv.statBonus.timer.min, inv.statBonus.timer.sec, "",
                  timer_flag.Enabled + timer_flag.Replace + timer_flag.OneShot,
                  "inv.statBonus.set"))

  return DRL_RET_SUCCESS
end -- inv.statBonus.load()


function inv.statBonus.reset()
  inv.statBonus.spellBonus = {}
  inv.statBonus.equipBonus = {}

  local retval = inv.statBonus.save()

  return retval
end -- inv.statBonus.reset


-- This is a moderately crude hack.  We would like a way to know what a character's spellup bonus
-- will be at any specific level.  The problem is that this varies dramatically from level to level.
-- Even worse, the spellup bonuses vary even more dramatically based on what moons are present and
-- if someone (e.g., a superhero!) gives a spellup.  So...what can we do?  This is a rough estimate
-- for what an "average" spellup should be for an "average" mort character based on averages I saw
-- during various morts.  Of course, this could be very different for someone else depending on what
-- classes are available, what spellup potions are used, and if someone else (a groupmate or clannee)
-- gives a spellup to the character.
--
-- The good news is that this table is just the starting point for a character.  The stat bonus
-- timer will periodically check what spell bonuses are present on the character and track a weighted
-- average and also the max value for each stat over time.  Those values will help improve accuracy
-- the longer someone uses this plugin.  If someone frequently has SH spellups their estimates will
-- eventually reflect that.  Similarly, if someone never bothers to spellup, that character's 
-- estimated stats will reflect that too after enough time passes.
--
-- Also, you should note that the spellup estimates are only used when real spellup values aren't
-- available.  If you are creating/wearing a set at your current level, we only use the actual/real
-- values.  However, if you want to estimate what equipment you would wear at a different level then
-- these estimates can be convenient until we have enough data to know what a particular character's
-- "typical" spellups are.

inv.statBonus.estimateTable = {}
inv.statBonus.estimateTable[  1] = { str =  1, int =  0, wis =  0, dex =  1, con =  0, luck =  0 }
inv.statBonus.estimateTable[  2] = { str =  1, int =  0, wis =  0, dex =  1, con =  0, luck =  0 }
inv.statBonus.estimateTable[  3] = { str =  1, int =  0, wis =  0, dex =  1, con =  0, luck =  0 }
inv.statBonus.estimateTable[  4] = { str =  1, int =  0, wis =  0, dex =  2, con =  0, luck =  0 }
inv.statBonus.estimateTable[  5] = { str =  1, int =  0, wis =  0, dex =  2, con =  2, luck =  0 }
inv.statBonus.estimateTable[  6] = { str =  2, int =  0, wis =  0, dex =  2, con =  2, luck =  0 }
inv.statBonus.estimateTable[  7] = { str =  2, int =  0, wis =  0, dex =  3, con =  3, luck =  0 }
inv.statBonus.estimateTable[  8] = { str =  2, int =  0, wis =  0, dex =  3, con =  3, luck =  0 }
inv.statBonus.estimateTable[  9] = { str =  2, int =  0, wis =  0, dex =  4, con =  4, luck =  0 }
inv.statBonus.estimateTable[ 10] = { str =  3, int =  0, wis =  0, dex =  4, con =  4, luck =  0 }
inv.statBonus.estimateTable[ 11] = { str =  3, int =  0, wis =  0, dex =  4, con =  4, luck =  0 }
inv.statBonus.estimateTable[ 12] = { str =  3, int =  0, wis =  0, dex =  5, con =  5, luck =  0 }
inv.statBonus.estimateTable[ 13] = { str =  3, int =  0, wis =  0, dex =  5, con =  5, luck =  0 }
inv.statBonus.estimateTable[ 14] = { str =  3, int =  0, wis =  0, dex =  5, con =  5, luck =  0 }
inv.statBonus.estimateTable[ 15] = { str =  7, int =  4, wis =  4, dex =  7, con =  7, luck =  4 }
inv.statBonus.estimateTable[ 16] = { str =  7, int =  4, wis =  4, dex =  7, con =  7, luck =  4 }
inv.statBonus.estimateTable[ 17] = { str =  8, int =  4, wis =  4, dex =  8, con =  8, luck =  4 }
inv.statBonus.estimateTable[ 18] = { str =  8, int =  4, wis =  4, dex =  8, con =  8, luck =  4 }
inv.statBonus.estimateTable[ 19] = { str =  9, int =  4, wis =  4, dex =  9, con =  9, luck =  4 }
inv.statBonus.estimateTable[ 20] = { str =  9, int =  4, wis =  5, dex =  9, con =  9, luck =  4 }
inv.statBonus.estimateTable[ 21] = { str = 10, int =  5, wis =  5, dex = 10, con = 10, luck =  4 }
inv.statBonus.estimateTable[ 22] = { str = 10, int =  5, wis =  5, dex = 10, con = 10, luck =  4 }
inv.statBonus.estimateTable[ 23] = { str = 11, int =  5, wis =  5, dex = 11, con = 11, luck =  4 }
inv.statBonus.estimateTable[ 24] = { str = 11, int =  5, wis =  5, dex = 11, con = 11, luck =  5 }
inv.statBonus.estimateTable[ 25] = { str = 12, int =  5, wis =  6, dex = 12, con = 12, luck =  5 }
inv.statBonus.estimateTable[ 26] = { str = 12, int =  6, wis =  6, dex = 12, con = 12, luck =  5 }
inv.statBonus.estimateTable[ 27] = { str = 13, int =  6, wis =  6, dex = 13, con = 13, luck =  5 }
inv.statBonus.estimateTable[ 28] = { str = 14, int =  6, wis =  6, dex = 13, con = 13, luck =  5 }
inv.statBonus.estimateTable[ 29] = { str = 14, int =  6, wis =  7, dex = 14, con = 14, luck =  5 }
inv.statBonus.estimateTable[ 30] = { str = 14, int =  7, wis =  7, dex = 14, con = 14, luck =  5 }
inv.statBonus.estimateTable[ 31] = { str = 15, int =  7, wis =  7, dex = 15, con = 15, luck =  5 }
inv.statBonus.estimateTable[ 32] = { str = 15, int =  7, wis =  7, dex = 15, con = 15, luck =  6 }
inv.statBonus.estimateTable[ 33] = { str = 15, int =  7, wis =  8, dex = 16, con = 16, luck =  6 }
inv.statBonus.estimateTable[ 34] = { str = 16, int =  8, wis =  8, dex = 16, con = 16, luck =  6 }
inv.statBonus.estimateTable[ 35] = { str = 16, int =  8, wis =  8, dex = 17, con = 17, luck =  6 }
inv.statBonus.estimateTable[ 36] = { str = 16, int =  8, wis =  9, dex = 17, con = 17, luck =  6 }
inv.statBonus.estimateTable[ 37] = { str = 17, int =  8, wis =  9, dex = 18, con = 18, luck =  6 }
inv.statBonus.estimateTable[ 38] = { str = 17, int =  9, wis =  9, dex = 18, con = 18, luck =  6 }
inv.statBonus.estimateTable[ 39] = { str = 17, int =  9, wis = 10, dex = 19, con = 19, luck =  6 }
inv.statBonus.estimateTable[ 40] = { str = 18, int =  9, wis = 10, dex = 19, con = 19, luck =  7 }
inv.statBonus.estimateTable[ 41] = { str = 18, int =  9, wis = 11, dex = 19, con = 19, luck =  7 }
inv.statBonus.estimateTable[ 42] = { str = 18, int = 10, wis = 11, dex = 20, con = 20, luck =  7 }
inv.statBonus.estimateTable[ 43] = { str = 19, int = 10, wis = 11, dex = 20, con = 20, luck =  7 }
inv.statBonus.estimateTable[ 44] = { str = 19, int = 10, wis = 12, dex = 21, con = 21, luck =  7 }
inv.statBonus.estimateTable[ 45] = { str = 19, int = 10, wis = 12, dex = 21, con = 21, luck =  8 }
inv.statBonus.estimateTable[ 46] = { str = 20, int = 11, wis = 12, dex = 22, con = 21, luck =  8 }
inv.statBonus.estimateTable[ 47] = { str = 20, int = 11, wis = 13, dex = 24, con = 23, luck = 10 }
inv.statBonus.estimateTable[ 48] = { str = 20, int = 11, wis = 13, dex = 25, con = 24, luck = 11 }
inv.statBonus.estimateTable[ 49] = { str = 20, int = 11, wis = 13, dex = 25, con = 24, luck = 11 }
inv.statBonus.estimateTable[ 50] = { str = 21, int = 12, wis = 13, dex = 25, con = 25, luck = 12 }
inv.statBonus.estimateTable[ 51] = { str = 21, int = 12, wis = 13, dex = 26, con = 25, luck = 12 }
inv.statBonus.estimateTable[ 52] = { str = 21, int = 13, wis = 14, dex = 26, con = 25, luck = 12 }
inv.statBonus.estimateTable[ 53] = { str = 22, int = 14, wis = 15, dex = 26, con = 25, luck = 12 }
inv.statBonus.estimateTable[ 54] = { str = 22, int = 14, wis = 15, dex = 26, con = 25, luck = 12 }
inv.statBonus.estimateTable[ 55] = { str = 22, int = 15, wis = 16, dex = 26, con = 26, luck = 12 }
inv.statBonus.estimateTable[ 56] = { str = 23, int = 15, wis = 17, dex = 26, con = 26, luck = 12 }
inv.statBonus.estimateTable[ 57] = { str = 23, int = 16, wis = 18, dex = 26, con = 26, luck = 12 }
inv.statBonus.estimateTable[ 58] = { str = 24, int = 18, wis = 18, dex = 26, con = 27, luck = 13 }
inv.statBonus.estimateTable[ 59] = { str = 24, int = 20, wis = 19, dex = 27, con = 27, luck = 13 }
inv.statBonus.estimateTable[ 60] = { str = 24, int = 20, wis = 19, dex = 27, con = 27, luck = 14 }
inv.statBonus.estimateTable[ 61] = { str = 24, int = 20, wis = 19, dex = 27, con = 27, luck = 15 }
inv.statBonus.estimateTable[ 62] = { str = 24, int = 20, wis = 19, dex = 28, con = 27, luck = 15 }
inv.statBonus.estimateTable[ 63] = { str = 24, int = 20, wis = 19, dex = 28, con = 27, luck = 16 }
inv.statBonus.estimateTable[ 64] = { str = 24, int = 20, wis = 19, dex = 28, con = 28, luck = 17 }
inv.statBonus.estimateTable[ 65] = { str = 24, int = 20, wis = 19, dex = 29, con = 28, luck = 18 }
inv.statBonus.estimateTable[ 66] = { str = 24, int = 20, wis = 19, dex = 29, con = 28, luck = 19 }
inv.statBonus.estimateTable[ 67] = { str = 24, int = 20, wis = 19, dex = 29, con = 28, luck = 20 }
inv.statBonus.estimateTable[ 68] = { str = 24, int = 20, wis = 19, dex = 30, con = 29, luck = 21 }
inv.statBonus.estimateTable[ 69] = { str = 24, int = 20, wis = 19, dex = 30, con = 29, luck = 21 }
inv.statBonus.estimateTable[ 70] = { str = 24, int = 21, wis = 19, dex = 30, con = 29, luck = 21 }
inv.statBonus.estimateTable[ 71] = { str = 24, int = 21, wis = 19, dex = 31, con = 29, luck = 22 }
inv.statBonus.estimateTable[ 72] = { str = 24, int = 21, wis = 19, dex = 31, con = 29, luck = 22 }
inv.statBonus.estimateTable[ 73] = { str = 24, int = 21, wis = 19, dex = 31, con = 30, luck = 23 }
inv.statBonus.estimateTable[ 74] = { str = 24, int = 22, wis = 19, dex = 32, con = 30, luck = 23 }
inv.statBonus.estimateTable[ 75] = { str = 24, int = 22, wis = 20, dex = 32, con = 30, luck = 23 }
inv.statBonus.estimateTable[ 76] = { str = 24, int = 22, wis = 20, dex = 32, con = 30, luck = 24 }
inv.statBonus.estimateTable[ 77] = { str = 24, int = 22, wis = 20, dex = 32, con = 31, luck = 24 }
inv.statBonus.estimateTable[ 78] = { str = 24, int = 23, wis = 20, dex = 33, con = 31, luck = 25 }
inv.statBonus.estimateTable[ 79] = { str = 24, int = 23, wis = 20, dex = 33, con = 31, luck = 25 }
inv.statBonus.estimateTable[ 80] = { str = 25, int = 23, wis = 20, dex = 33, con = 31, luck = 25 }
inv.statBonus.estimateTable[ 81] = { str = 25, int = 24, wis = 20, dex = 34, con = 32, luck = 26 }
inv.statBonus.estimateTable[ 82] = { str = 25, int = 24, wis = 20, dex = 34, con = 32, luck = 26 }
inv.statBonus.estimateTable[ 83] = { str = 25, int = 24, wis = 20, dex = 34, con = 33, luck = 26 }
inv.statBonus.estimateTable[ 84] = { str = 26, int = 24, wis = 20, dex = 35, con = 33, luck = 26 }
inv.statBonus.estimateTable[ 85] = { str = 26, int = 25, wis = 21, dex = 35, con = 33, luck = 26 }
inv.statBonus.estimateTable[ 86] = { str = 26, int = 25, wis = 21, dex = 36, con = 34, luck = 27 }
inv.statBonus.estimateTable[ 87] = { str = 26, int = 25, wis = 21, dex = 36, con = 34, luck = 27 }
inv.statBonus.estimateTable[ 88] = { str = 27, int = 26, wis = 22, dex = 36, con = 34, luck = 27 }
inv.statBonus.estimateTable[ 89] = { str = 27, int = 26, wis = 22, dex = 36, con = 34, luck = 28 }
inv.statBonus.estimateTable[ 90] = { str = 28, int = 27, wis = 22, dex = 36, con = 34, luck = 28 }
inv.statBonus.estimateTable[ 91] = { str = 28, int = 27, wis = 22, dex = 36, con = 34, luck = 28 }
inv.statBonus.estimateTable[ 92] = { str = 29, int = 28, wis = 22, dex = 36, con = 34, luck = 28 }
inv.statBonus.estimateTable[ 93] = { str = 29, int = 28, wis = 22, dex = 36, con = 34, luck = 29 }
inv.statBonus.estimateTable[ 94] = { str = 30, int = 28, wis = 22, dex = 36, con = 34, luck = 29 }
inv.statBonus.estimateTable[ 95] = { str = 30, int = 29, wis = 22, dex = 36, con = 34, luck = 29 }
inv.statBonus.estimateTable[ 96] = { str = 31, int = 29, wis = 22, dex = 36, con = 34, luck = 30 }
inv.statBonus.estimateTable[ 97] = { str = 31, int = 30, wis = 22, dex = 36, con = 34, luck = 30 }
inv.statBonus.estimateTable[ 98] = { str = 32, int = 30, wis = 22, dex = 37, con = 35, luck = 30 }
inv.statBonus.estimateTable[ 99] = { str = 32, int = 31, wis = 22, dex = 37, con = 35, luck = 30 }
inv.statBonus.estimateTable[100] = { str = 32, int = 31, wis = 23, dex = 37, con = 35, luck = 30 }
inv.statBonus.estimateTable[101] = { str = 32, int = 31, wis = 24, dex = 38, con = 36, luck = 30 }
inv.statBonus.estimateTable[102] = { str = 32, int = 32, wis = 25, dex = 38, con = 36, luck = 30 }
inv.statBonus.estimateTable[103] = { str = 32, int = 32, wis = 26, dex = 38, con = 37, luck = 30 }
inv.statBonus.estimateTable[104] = { str = 32, int = 32, wis = 27, dex = 38, con = 37, luck = 30 }
inv.statBonus.estimateTable[105] = { str = 33, int = 33, wis = 28, dex = 39, con = 38, luck = 30 }
inv.statBonus.estimateTable[106] = { str = 33, int = 33, wis = 29, dex = 39, con = 38, luck = 30 }
inv.statBonus.estimateTable[107] = { str = 33, int = 33, wis = 30, dex = 39, con = 39, luck = 30 }
inv.statBonus.estimateTable[108] = { str = 33, int = 33, wis = 31, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[109] = { str = 33, int = 34, wis = 32, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[110] = { str = 33, int = 35, wis = 33, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[111] = { str = 33, int = 35, wis = 33, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[112] = { str = 33, int = 36, wis = 33, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[113] = { str = 33, int = 36, wis = 34, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[114] = { str = 33, int = 37, wis = 34, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[115] = { str = 33, int = 37, wis = 34, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[116] = { str = 33, int = 37, wis = 35, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[117] = { str = 33, int = 38, wis = 35, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[118] = { str = 33, int = 38, wis = 36, dex = 40, con = 39, luck = 30 }
inv.statBonus.estimateTable[119] = { str = 33, int = 39, wis = 36, dex = 40, con = 40, luck = 31 }
inv.statBonus.estimateTable[120] = { str = 34, int = 40, wis = 37, dex = 41, con = 40, luck = 31 }
inv.statBonus.estimateTable[121] = { str = 34, int = 42, wis = 38, dex = 42, con = 40, luck = 31 }
inv.statBonus.estimateTable[122] = { str = 34, int = 44, wis = 39, dex = 43, con = 40, luck = 31 }
inv.statBonus.estimateTable[123] = { str = 34, int = 46, wis = 40, dex = 44, con = 40, luck = 32 }
inv.statBonus.estimateTable[124] = { str = 34, int = 47, wis = 42, dex = 45, con = 40, luck = 32 }
inv.statBonus.estimateTable[125] = { str = 35, int = 48, wis = 43, dex = 46, con = 41, luck = 32 }
inv.statBonus.estimateTable[126] = { str = 35, int = 50, wis = 44, dex = 47, con = 41, luck = 32 }
inv.statBonus.estimateTable[127] = { str = 35, int = 51, wis = 46, dex = 48, con = 41, luck = 32 }
inv.statBonus.estimateTable[128] = { str = 35, int = 52, wis = 48, dex = 49, con = 41, luck = 32 }
inv.statBonus.estimateTable[129] = { str = 35, int = 52, wis = 50, dex = 50, con = 42, luck = 32 }
inv.statBonus.estimateTable[130] = { str = 36, int = 53, wis = 51, dex = 51, con = 42, luck = 32 }
inv.statBonus.estimateTable[131] = { str = 36, int = 53, wis = 51, dex = 52, con = 42, luck = 32 }
inv.statBonus.estimateTable[132] = { str = 36, int = 53, wis = 52, dex = 52, con = 43, luck = 33 }
inv.statBonus.estimateTable[133] = { str = 37, int = 53, wis = 53, dex = 53, con = 43, luck = 33 }
inv.statBonus.estimateTable[134] = { str = 37, int = 54, wis = 54, dex = 53, con = 44, luck = 33 }
inv.statBonus.estimateTable[135] = { str = 38, int = 54, wis = 54, dex = 54, con = 44, luck = 33 }
inv.statBonus.estimateTable[136] = { str = 38, int = 54, wis = 55, dex = 54, con = 45, luck = 33 }
inv.statBonus.estimateTable[137] = { str = 39, int = 54, wis = 55, dex = 55, con = 45, luck = 33 }
inv.statBonus.estimateTable[138] = { str = 39, int = 54, wis = 55, dex = 55, con = 46, luck = 33 }
inv.statBonus.estimateTable[139] = { str = 40, int = 54, wis = 56, dex = 56, con = 46, luck = 33 }
inv.statBonus.estimateTable[140] = { str = 41, int = 55, wis = 56, dex = 58, con = 47, luck = 34 }
inv.statBonus.estimateTable[141] = { str = 42, int = 55, wis = 56, dex = 59, con = 47, luck = 34 }
inv.statBonus.estimateTable[142] = { str = 44, int = 55, wis = 56, dex = 60, con = 47, luck = 35 }
inv.statBonus.estimateTable[143] = { str = 45, int = 55, wis = 56, dex = 61, con = 48, luck = 35 }
inv.statBonus.estimateTable[144] = { str = 47, int = 55, wis = 56, dex = 62, con = 48, luck = 36 }
inv.statBonus.estimateTable[145] = { str = 48, int = 55, wis = 56, dex = 63, con = 49, luck = 36 }
inv.statBonus.estimateTable[146] = { str = 49, int = 55, wis = 56, dex = 64, con = 49, luck = 37 }
inv.statBonus.estimateTable[147] = { str = 50, int = 55, wis = 56, dex = 65, con = 50, luck = 37 }
inv.statBonus.estimateTable[148] = { str = 51, int = 55, wis = 56, dex = 66, con = 50, luck = 38 }
inv.statBonus.estimateTable[149] = { str = 51, int = 55, wis = 56, dex = 67, con = 51, luck = 38 }
inv.statBonus.estimateTable[150] = { str = 51, int = 55, wis = 56, dex = 67, con = 52, luck = 38 }
inv.statBonus.estimateTable[151] = { str = 52, int = 55, wis = 56, dex = 67, con = 54, luck = 38 }
inv.statBonus.estimateTable[152] = { str = 52, int = 55, wis = 56, dex = 67, con = 56, luck = 38 }
inv.statBonus.estimateTable[153] = { str = 52, int = 55, wis = 56, dex = 67, con = 58, luck = 38 }
inv.statBonus.estimateTable[154] = { str = 53, int = 55, wis = 56, dex = 67, con = 60, luck = 38 }
inv.statBonus.estimateTable[155] = { str = 53, int = 55, wis = 56, dex = 67, con = 61, luck = 38 }
inv.statBonus.estimateTable[156] = { str = 53, int = 55, wis = 56, dex = 67, con = 62, luck = 38 }
inv.statBonus.estimateTable[157] = { str = 53, int = 55, wis = 56, dex = 67, con = 64, luck = 39 }
inv.statBonus.estimateTable[158] = { str = 54, int = 55, wis = 56, dex = 67, con = 66, luck = 39 }
inv.statBonus.estimateTable[159] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[160] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[161] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[162] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[163] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[164] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[165] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[166] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[167] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[168] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[169] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[170] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[171] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[172] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[173] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[174] = { str = 54, int = 55, wis = 56, dex = 67, con = 68, luck = 39 }
inv.statBonus.estimateTable[175] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[176] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[177] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[178] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[179] = { str = 54, int = 55, wis = 56, dex = 68, con = 68, luck = 39 }
inv.statBonus.estimateTable[180] = { str = 54, int = 56, wis = 56, dex = 69, con = 68, luck = 40 }
inv.statBonus.estimateTable[181] = { str = 54, int = 56, wis = 56, dex = 69, con = 68, luck = 40 }
inv.statBonus.estimateTable[182] = { str = 54, int = 57, wis = 56, dex = 69, con = 69, luck = 40 }
inv.statBonus.estimateTable[183] = { str = 54, int = 57, wis = 56, dex = 69, con = 69, luck = 40 }
inv.statBonus.estimateTable[184] = { str = 55, int = 57, wis = 56, dex = 70, con = 69, luck = 41 }
inv.statBonus.estimateTable[185] = { str = 55, int = 58, wis = 56, dex = 70, con = 69, luck = 41 }
inv.statBonus.estimateTable[186] = { str = 55, int = 58, wis = 56, dex = 70, con = 69, luck = 41 }
inv.statBonus.estimateTable[187] = { str = 55, int = 59, wis = 56, dex = 70, con = 70, luck = 41 }
inv.statBonus.estimateTable[188] = { str = 56, int = 59, wis = 56, dex = 70, con = 70, luck = 42 }
inv.statBonus.estimateTable[189] = { str = 56, int = 60, wis = 56, dex = 70, con = 70, luck = 42 }
inv.statBonus.estimateTable[190] = { str = 57, int = 62, wis = 57, dex = 71, con = 70, luck = 43 }
inv.statBonus.estimateTable[191] = { str = 57, int = 64, wis = 57, dex = 71, con = 70, luck = 43 }
inv.statBonus.estimateTable[192] = { str = 57, int = 66, wis = 58, dex = 71, con = 70, luck = 44 }
inv.statBonus.estimateTable[193] = { str = 57, int = 68, wis = 59, dex = 72, con = 70, luck = 44 }
inv.statBonus.estimateTable[194] = { str = 57, int = 70, wis = 59, dex = 72, con = 70, luck = 44 }
inv.statBonus.estimateTable[195] = { str = 57, int = 72, wis = 60, dex = 72, con = 70, luck = 45 }
inv.statBonus.estimateTable[196] = { str = 57, int = 74, wis = 60, dex = 72, con = 70, luck = 45 }
inv.statBonus.estimateTable[197] = { str = 57, int = 76, wis = 61, dex = 73, con = 70, luck = 46 }
inv.statBonus.estimateTable[198] = { str = 57, int = 77, wis = 61, dex = 73, con = 70, luck = 46 }
inv.statBonus.estimateTable[199] = { str = 57, int = 78, wis = 62, dex = 73, con = 70, luck = 47 }
inv.statBonus.estimateTable[200] = { str = 57, int = 78, wis = 62, dex = 73, con = 70, luck = 47 }
inv.statBonus.estimateTable[201] = { str = 57, int = 78, wis = 62, dex = 73, con = 70, luck = 47 }
inv.statBonus.estimateTable[202] = { str = 57, int = 78, wis = 63, dex = 73, con = 70, luck = 47 }
inv.statBonus.estimateTable[203] = { str = 57, int = 78, wis = 63, dex = 73, con = 70, luck = 47 }
inv.statBonus.estimateTable[204] = { str = 57, int = 79, wis = 63, dex = 73, con = 70, luck = 48 }
inv.statBonus.estimateTable[205] = { str = 57, int = 79, wis = 64, dex = 73, con = 70, luck = 48 }
inv.statBonus.estimateTable[206] = { str = 57, int = 79, wis = 64, dex = 73, con = 71, luck = 48 }
inv.statBonus.estimateTable[207] = { str = 57, int = 79, wis = 64, dex = 73, con = 71, luck = 48 }
inv.statBonus.estimateTable[208] = { str = 57, int = 79, wis = 65, dex = 73, con = 71, luck = 49 }
inv.statBonus.estimateTable[209] = { str = 57, int = 80, wis = 65, dex = 73, con = 71, luck = 49 }
inv.statBonus.estimateTable[210] = { str = 57, int = 78, wis = 62, dex = 73, con = 70, luck = 47 }
inv.statBonus.estimateTable[211] = { str = 70, int = 86, wis = 70, dex = 105, con = 90, luck = 65 }


function inv.statBonus.estimate(level)
  level = tonumber(level or "")
  if (level == nil) then
    dbot.warn("inv.statBonus.estimate: Missing level parameter")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  -- Minor hack: spell bonuses don't change much once we SH
  if (level > 211) then
    level = 211
  end -- if

  if (inv.statBonus.estimateTable[level] ~= nil) then
    return inv.statBonus.estimateTable[level], DRL_RET_SUCCESS
  else
    dbot.warn("Failed to get stat bonus estimate for level " .. level .. ": estimate does not exist")
    return nil, DRL_RET_MISSING_ENTRY
  end -- if
end -- inv.statBonus.estimate


-- Returns a table of the form { int = 1, luck = 3, ... } where the values of each stat in the
-- table indicate how many points of that stat are available to equipment before we hit the max
-- stats for the specified level.
-- Note: This function is synchronous
invStatBonusTypeCurrent = "current"
invStatBonusTypeAve     = "average"
invStatBonusTypeMax     = "max"
function inv.statBonus.get(level, bonusType)
  local spellBonus
  local equipBonus

  -- Be paranoid about input params
  level = tonumber(level or "")
  if (level == nil) then
    dbot.warn("inv.statBonus.get: Invalid level parameter")
    return nil, DRL_RET_INVALID_PARAM
  end -- if

  -- Resolve the spell bonus for this (level, bonusType).  When we have a real
  -- prior measurement for this level use it directly; otherwise fall back to
  -- an estimate (for ave) or zeros (for max) computed locally without writing
  -- back to inv.statBonus.spellBonus.  Earlier versions of this code seeded
  -- spellBonus[level] from the estimate table and then setCR's weighted-
  -- average treated that estimate as a prior real sample, slowly drifting the
  -- recorded average away from the truth over many sessions.  See audit H5.
  if (bonusType == invStatBonusTypeCurrent) then
    spellBonus = inv.statBonus.currentBonus

  elseif (bonusType == invStatBonusTypeAve) then
    if (inv.statBonus.spellBonus[level] ~= nil) and
       (inv.statBonus.spellBonus[level].ave ~= nil) then
      spellBonus = inv.statBonus.spellBonus[level].ave
    else
      local estimate, retval = inv.statBonus.estimate(level)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.warn("inv.statBonus.get: Failed to get estimate for level " .. level .. ": " ..
                  dbot.retval.getString(retval))
        return nil, retval
      end -- if
      spellBonus = estimate
    end -- if

  elseif (bonusType == invStatBonusTypeMax) then
    if (inv.statBonus.spellBonus[level] ~= nil) and
       (inv.statBonus.spellBonus[level].max ~= nil) then
      spellBonus = inv.statBonus.spellBonus[level].max
    else
      -- No prior measurement; report zeros so caller doesn't over-credit
      -- equipment against an unseen spellup.
      spellBonus = { int = 0, luck = 0, wis = 0, str = 0, dex = 0, con = 0 }
    end -- if
  end -- if

  -- Now that we know the spell bonus, calculate how many bonus stats are available to equipment
  local levelBonus = level - (10 * dbot.gmcp.getTier())
  if (levelBonus < 25) then
    levelBonus = 25
  elseif (levelBonus > 200) then
    levelBonus = 200
  end -- if

  local cappedInt  = levelBonus - spellBonus.int
  local cappedWis  = levelBonus - spellBonus.wis
  local cappedLuck = levelBonus - spellBonus.luck
  local cappedStr  = levelBonus - spellBonus.str
  local cappedDex  = levelBonus - spellBonus.dex
  local cappedCon  = levelBonus - spellBonus.con

  if (cappedInt < 0) then
    cappedInt = 0
  end -- if
  if (cappedWis < 0) then
    cappedWis = 0
  end -- if
  if (cappedLuck < 0) then
    cappedLuck = 0
  end -- if
  if (cappedStr < 0) then
    cappedStr = 0
  end -- if
  if (cappedDex < 0) then
    cappedDex = 0
  end -- if
  if (cappedCon < 0) then
    cappedCon = 0
  end -- if

  inv.statBonus.equipBonus[level] = { int  = cappedInt,
                                      wis  = cappedWis,
                                      luck = cappedLuck,
                                      str  = cappedStr,
                                      dex  = cappedDex,
                                      con  = cappedCon }

  return inv.statBonus.equipBonus[level], DRL_RET_SUCCESS

end -- inv.statBonus.get


function inv.statBonus.set()
  wait.make(inv.statBonus.setCR)
end -- inv.statBonus.set


-- This function must run in a co-routine because it potentially blocks
function inv.statBonus.setCR()
  local retval = DRL_RET_SUCCESS
  local level = tonumber(dbot.gmcp.getLevel() or "")
  local charState = dbot.gmcp.getState()

  inv.statBonus.bonusInProgress = true

  -- If we are in the active state (i.e., not AFK, sleeping, running, writing a note, etc.) then
  -- we get the current bonuses
  if (charState == dbot.stateActive) then

    dbot.prompt.hide()

    -- Run the stats command so that we can trigger on the stats and save them
    local resultData = dbot.callback.new()
    local commandArray = {}
    table.insert(commandArray, "stats")
    table.insert(commandArray, "echo " .. inv.statBonus.closingMsg)
    retval = dbot.execute.safe.commands(commandArray, inv.statBonus.setSetupFn, nil,
                                        dbot.callback.default, resultData)
    if (retval ~= DRL_RET_SUCCESS) then
      dbot.warn("inv.statBonus.setCR: Failed to safely execute \"@Gstats@W\": " ..
                dbot.retval.getString(retval))
      dbot.deleteTrigger(inv.statBonus.trigger.startName)
    else
      -- Wait for the callback to confirm that the safe execution completed
      retval = dbot.callback.wait(resultData, 10)
      if (retval ~= DRL_RET_SUCCESS) then
        dbot.note("Skipping statBonus \"stats\" request: " .. dbot.retval.getString(retval))
      end -- if

      -- Wait for the trigger to fill in the stat bonuses due to spells that are active right now.
      -- We've already allocated quite a bit of time to handle the callback above.  As a result,
      -- the trigger should have already kicked off at this point.  We allow it just a little more
      -- time though just to be paranoid...
      local totTime = 0
      local timeout = 2
      while (inv.statBonus.bonusInProgress == true) do
        wait.time(drlSpinnerPeriodDefault)
        totTime = totTime + drlSpinnerPeriodDefault
        if (totTime > timeout) then
          dbot.debug("inv.statBonus.setCR: Failed to get spell stat bonus information: timed out")
          dbot.deleteTrigger(inv.statBonus.trigger.startName)
          retval = DRL_RET_TIMEOUT
          break
        end -- if
      end -- while
    end -- if

    dbot.prompt.show()

  else
    dbot.debug("Skipping @Glevel " .. level .. " @Wspell bonus update: you are in state \"@C" .. 
               dbot.gmcp.getStateString(charState) .. "@W\"")
    retval = DRL_RET_NOT_ACTIVE
  end -- if

  -- Update the spell bonus stats if we were able to get new stats
  if (retval == DRL_RET_SUCCESS) then
    -- If we don't have any bonus history yet, start with the bonuses we just discovered
    if (inv.statBonus.spellBonus[level] == nil) then
      inv.statBonus.spellBonus[level] = {}
      inv.statBonus.spellBonus[level].ave = dbot.table.getCopy(inv.statBonus.currentBonus)
      inv.statBonus.spellBonus[level].max = dbot.table.getCopy(inv.statBonus.currentBonus)

    -- If we have bonus history, average the current stats with what we had before.  This gives
    -- recent bonus stat scans a higher weight than older scans.  The weighted average helps keep
    -- things up-to-date as spellups improve with additional classes.
    else
      local statList = "int luck wis str dex con"
      for spellStat in statList:gmatch("%S+") do
        -- Update the weighted average (current stats are weighted 50% by default)
        inv.statBonus.spellBonus[level].ave[spellStat] = 
          (inv.statBonus.currentBonus[spellStat] + inv.statBonus.spellBonus[level].ave[spellStat]) / 2  

        -- Update the max stats
        if (inv.statBonus.currentBonus[spellStat] > inv.statBonus.spellBonus[level].max[spellStat]) then
          inv.statBonus.spellBonus[level].max[spellStat] = inv.statBonus.currentBonus[spellStat]
        end -- if
      end -- for
    end -- if

    dbot.debug("Updated @GL" .. level .. "@W spell bonuses: " .. 
               string.format("@Cint@W=@G%.2f@W, @Cluck@W=@G%.2f@W, @Cwis@W=@G%.2f@W, " ..
                             "@Cstr@W=@G%.2f@W, @Cdex@W=@G%.2f@W, @Ccon@W=@G%.2f@w",
                             inv.statBonus.spellBonus[level].ave.int,
                             inv.statBonus.spellBonus[level].ave.luck,
                             inv.statBonus.spellBonus[level].ave.wis,
                             inv.statBonus.spellBonus[level].ave.str,
                             inv.statBonus.spellBonus[level].ave.dex,
                             inv.statBonus.spellBonus[level].ave.con))

    inv.statBonus.save()
  end -- if

  inv.statBonus.timer.update(inv.statBonus.timer.min, inv.statBonus.timer.sec)

  return retval
end -- inv.statBonus.setCR


function inv.statBonus.setSetupFn()
  -- Run the "stats" command and pick off the current spell bonuses
  check (AddTriggerEx(inv.statBonus.trigger.startName,
                      "^(.*Str.*Int.*Wis.*Dex.*Con.*Luck.*Total|You are flagged as remorting).*$",
                      "inv.statBonus.checkRemort(\"%1\")",
                      drlTriggerFlagsBaseline + trigger_flag.OneShot + trigger_flag.OmitFromOutput,
                      custom_colour.Custom11,
                      0, "", "", sendto.script, 0))
end -- inv.statBonus.setSetupFn


function inv.statBonus.checkRemort(line)
  if (line == "You are flagged as remorting") then
    dbot.note("Skipping stat bonus check -- You are remorting and the \"stats\" command is not available")
  else
    EnableTrigger(inv.statBonus.trigger.getName, true)
  end -- if
end -- inv.statBonus.checkRemort


inv.statBonus.timer      = {}
inv.statBonus.timer.name = "drlInvStatBonusTimer"
inv.statBonus.timer.min  = 5
inv.statBonus.timer.sec  = 0

function inv.statBonus.timer.update(min, sec)
  min = tonumber(min or "")
  sec = tonumber(sec or "")
  if (min == nil) or (sec == nil) then
    dbot.warn("inv.statBonus.timer.update: missing parameters")
    return DRL_RET_INVALID_PARAM
  end -- if

  dbot.debug("Scheduling stat bonus timer in " .. min .. " minutes, " .. sec .. " seconds")

  -- If we are idle, don't keep scanning the spellup stats.  They most likely aren't accurate at this
  -- point and running the stats could keep someone logged in when they'd prefer to idle out.
  local currentTime = dbot.getTime()
  if (currentTime - drlLastCmdTime > drlIdleTime) then
    dbot.debug("Halting statBonus thread.  We are idle!")
    drlIsIdle = true
  else
    check (AddTimer(inv.statBonus.timer.name, 0, min, sec, "",
                    timer_flag.Enabled + timer_flag.Replace + timer_flag.OneShot,
                    "inv.statBonus.set"))
  end -- if

end -- inv.statBonus.timer.update


inv.statBonus.trigger = {}

inv.statBonus.trigger.getName   = "drlInvStatBonusTriggerGet"
inv.statBonus.trigger.startName = "drlInvStatBonusTriggerStart"

function inv.statBonus.trigger.get(line)

  -- Look for the current spells bonus
  local matchStart, matchEnd, eqStr, eqInt, eqWis, eqDex, eqCon, eqLuck = 
    string.find(line, "Spells Bonus%s+:%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+.*$")

  if (matchStart ~= nil) then
    inv.statBonus.currentBonus.str  = tonumber(eqStr)
    inv.statBonus.currentBonus.int  = tonumber(eqInt)
    inv.statBonus.currentBonus.wis  = tonumber(eqWis)
    inv.statBonus.currentBonus.dex  = tonumber(eqDex)
    inv.statBonus.currentBonus.con  = tonumber(eqCon)
    inv.statBonus.currentBonus.luck = tonumber(eqLuck)

    inv.statBonus.bonusInProgress = false

    dbot.debug("Spells bonus: str=" .. eqStr .. ", int=" .. eqInt .. ", wis=" .. eqWis ..
               ", dex=" .. eqDex .. ", con=" .. eqCon .. ", luck=" .. eqLuck)
  end -- if

  -- Shut off the trigger if we hit the end of the stats output
  if (line == inv.statBonus.closingMsg) then
    EnableTrigger(inv.statBonus.trigger.getName, false)
  end -- if

end -- inv.statBonus.trigger.get


