#ifndef CLSQLITE3_H
#define CLSQLITE3_H

/// Open the `lsqlite3` library into a Lua state, leaving its module table on
/// the stack (returns 1). `lua_state` is an opaque `lua_State *` — kept
/// `void *` here so this Swift-facing header doesn't pull in `lua.h` and
/// clash with the `CLua` module. See `shim.c`.
int proteles_open_lsqlite3(void *lua_state);

#endif
