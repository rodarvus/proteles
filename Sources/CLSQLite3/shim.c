// Bridges the vendored lsqlite3 entry point to a void*-typed function so the
// CLSQLite3 module's public header doesn't expose lua.h (which would clash
// with the CLua module when both are imported into Swift).
#include "lua.h"
#include "CLSQLite3.h"

extern int luaopen_lsqlite3(lua_State *L);

int proteles_open_lsqlite3(void *lua_state) {
    return luaopen_lsqlite3((lua_State *)lua_state);
}
