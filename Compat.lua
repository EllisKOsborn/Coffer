local addonName, Coffer = ...

-- World of Warcraft: Forever runs on the modern (Midnight-era) client engine with its own
-- interface number (16001). Two consequences, both of which KiwiFarm also handles for
-- its Forever build:
--   * Many classic global APIs only exist under C_* namespaces now. Coffer's own panel
--     showed "238g 4s 73c" in-game - the plain-text fallback for a missing
--     GetCoinTextureString - which is how this was confirmed.
--   * Some event payloads can be "secret" values that addon code may not read; any
--     string operation on one raises an error, so every payload is checked first.

local C_Item = C_Item

Coffer.GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
Coffer.GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
Coffer.CanAccess = canaccessvalue or function() return true end
Coffer.IsSecret = issecretvalue or function() return false end

-- True when every given value can be read by addon code.
function Coffer:Readable(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil and (self.IsSecret(value) or not self.CanAccess(value)) then
            return false
        end
    end
    return true
end

-- Builds a Lua pattern from a Blizzard format string (e.g. LOOT_ITEM_SELF), escaping
-- pattern-magic characters first so localized templates containing ".", "(", "-" etc.
-- match literally, then turning %s / %d placeholders into captures.
function Coffer:PatternFromTemplate(template, anchored)
    if type(template) ~= "string" then return nil end
    local pattern = template:gsub("%%%d%$([sd])", "%%%1") -- positional "%1$s" -> "%s"
    pattern = pattern:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    pattern = pattern:gsub("%%s", "(.+)")
    pattern = pattern:gsub("%%d", "(%%d+)")
    if anchored then
        pattern = "^" .. pattern .. "$"
    end
    return pattern
end
