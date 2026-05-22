#include "clua_timeout.h"
#include "lauxlib.h"
#include <time.h>

/* Registry key under which the absolute monotonic deadline (seconds) is
 * stored for the running chunk. */
static const char *const CLUA_DEADLINE_KEY = "proteles_deadline";

static double clua_now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1.0e9;
}

/* Count hook: abort if we're past the registry-stored deadline. */
static void clua_timeout_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    lua_pushstring(L, CLUA_DEADLINE_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    double deadline = lua_tonumber(L, -1);
    lua_pop(L, 1);
    if (deadline > 0.0 && clua_now_seconds() > deadline) {
        luaL_error(L, "proteles:timeout: script exceeded its execution budget");
    }
}

void clua_install_timeout(lua_State *L, double seconds, int count) {
    double deadline = (seconds > 0.0) ? clua_now_seconds() + seconds : 0.0;
    lua_pushstring(L, CLUA_DEADLINE_KEY);
    lua_pushnumber(L, deadline);
    lua_rawset(L, LUA_REGISTRYINDEX);
    if (seconds > 0.0) {
        lua_sethook(L, clua_timeout_hook, LUA_MASKCOUNT, count);
    } else {
        lua_sethook(L, NULL, 0, 0);
    }
}

void clua_clear_timeout(lua_State *L) {
    lua_sethook(L, NULL, 0, 0);
}
