const fs = require("fs");
const path = require("path");
const { lua, lauxlib, to_luastring } = require("fengari");

const files = process.argv.slice(2);
let anyError = false;

for (const file of files) {
    const code = fs.readFileSync(file, "utf8");
    const L = lauxlib.luaL_newstate();
    const status = lauxlib.luaL_loadstring(L, to_luastring(code));
    if (status !== lua.LUA_OK) {
        anyError = true;
        const msg = lua.lua_tojsstring(L, -1);
        console.log(`SYNTAX ERROR in ${file}:`);
        console.log("  " + msg);
    } else {
        console.log(`OK: ${file} parses cleanly (Lua 5.3 grammar via fengari)`);
    }
}

process.exit(anyError ? 1 : 0);
