#ifndef CLUA_TIMEOUT_H
#define CLUA_TIMEOUT_H

#include "lua.h"

/* Wall-clock execution timeout for the Lua VM (PLAN.md §7.7 / D-10).
 *
 * `clua_install_timeout` records a deadline `seconds` from now and installs
 * a count hook firing every `count` VM instructions; once the deadline
 * passes, the running chunk is aborted with a Lua error tagged
 * "proteles:timeout". This stops an accidental infinite loop from freezing
 * the session. `seconds <= 0` clears the hook instead.
 *
 * The deadline lives in the state's registry, so distinct lua_States (and
 * thus distinct LuaRuntimes) are independent. */
void clua_install_timeout(lua_State *L, double seconds, int count);

/* Remove any installed hook. */
void clua_clear_timeout(lua_State *L);

#endif /* CLUA_TIMEOUT_H */
