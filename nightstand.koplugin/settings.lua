local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}

-- Every setting with a value it has before it is ever set. Those not here
-- (a sign-in, a choice the screens derive) start as nil.
Settings.DEFAULTS = {
    replace_file_browser = true,
    server = "",
    username = "",
    password = "",
    books_dir = "",
    refresh_on_wake = true,
    wifi_only = true,
    -- chosen once on the first start (setup.lua), "off" until then
    sync_service = "off",
    sync_url = "",
    sync_username = "",
    discover_list = "recs",
    vendor = "kobo",
    custom_vendors = {},
}

function Settings:open()
    if self.store then return self.store end
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/nightstand.lua")
    return self.store
end

function Settings:get(key)
    local value = self:open():readSetting(key)
    if value ~= nil then return value end
    value = self.DEFAULTS[key]
    -- a default table must not be changed through what get() hands out
    if type(value) == "table" then return require("util").tableDeepCopy(value) end
    return value
end

--- Whether `key` was ever set, its default aside.
function Settings:has(key)
    return self:open():readSetting(key) ~= nil
end

function Settings:set(key, value)
    self:open():saveSetting(key, value)
    self:open():flush()
end

function Settings:delete(key)
    self:open():delSetting(key)
    self:open():flush()
end

function Settings:toggle(key)
    self:set(key, not self:get(key))
end

--- The configured folder, or ~/Books when it exists and nothing is set.
function Settings:booksDir()
    local dir = self:get("books_dir")
    if dir ~= "" then return dir end
    local home = os.getenv("HOME")
    if home then
        local lfs = require("libs/libkoreader-lfs")
        local guess = home .. "/Books"
        if lfs.attributes(guess, "mode") == "directory" then return guess end
    end
    return ""
end

return Settings
