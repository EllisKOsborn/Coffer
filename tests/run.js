const { lua, lauxlib, lualib, to_luastring } = require("fengari");

const scriptPath = process.argv[2];
const addonDir = process.argv[3];

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const status = lauxlib.luaL_loadfile(L, to_luastring(scriptPath));
if (status !== lua.LUA_OK) {
    console.log("LOAD ERROR: " + lua.lua_tojsstring(L, -1));
    process.exit(1);
}

lua.lua_pushstring(L, to_luastring(addonDir));
const callStatus = lua.lua_pcall(L, 1, lua.LUA_MULTRET, 0);
if (callStatus !== lua.LUA_OK) {
    console.log("RUNTIME ERROR: " + lua.lua_tojsstring(L, -1));
    process.exit(1);
}
