local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}

-- Layout ids are stable: they are written to disk and referenced by the
-- layout modules, so renaming one breaks existing installs.
Settings.LAYOUTS = {
    { id = "shelf",     name = "Shelf stack" },
    { id = "hero_grid", name = "Hero and grid" },
}

Settings.DEFAULTS = {
    layout = "shelf",
    replace_file_browser = true,
    server = "",
    username = "",
    password = "",
    books_dir = "",
    refresh_on_wake = true,
    wifi_only = true,
}

function Settings:open()
    if self.store then return self.store end
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/nightstand.lua")
    return self.store
end

function Settings:get(key)
    local value = self:open():readSetting(key)
    if value == nil then return self.DEFAULTS[key] end
    return value
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

function Settings:layoutName()
    local current = self:get("layout")
    for _, layout in ipairs(self.LAYOUTS) do
        if layout.id == current then return layout.name end
    end
    return current
end

return Settings
