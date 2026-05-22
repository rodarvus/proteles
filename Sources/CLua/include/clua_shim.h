#ifndef CLUA_SHIM_H
#define CLUA_SHIM_H

#include "lua.h"

/* Several Lua C-API entry points are preprocessor macros, which Swift's C
 * importer can't see. Re-expose the ones we need as static-inline functions
 * so they're callable from Swift. */

static inline const char *clua_tostring(lua_State *L, int index) {
    return lua_tolstring(L, index, NULL);
}

static inline void clua_pop(lua_State *L, int n) {
    lua_settop(L, -(n) - 1);
}

static inline void clua_pushcfunction(lua_State *L, lua_CFunction fn) {
    lua_pushcclosure(L, fn, 0);
}

static inline int clua_isnil(lua_State *L, int index) {
    return lua_type(L, index) == LUA_TNIL;
}

static inline void clua_getglobal(lua_State *L, const char *name) {
    lua_getfield(L, LUA_GLOBALSINDEX, name);
}

static inline void clua_setglobal(lua_State *L, const char *name) {
    lua_setfield(L, LUA_GLOBALSINDEX, name);
}

#endif /* CLUA_SHIM_H */
