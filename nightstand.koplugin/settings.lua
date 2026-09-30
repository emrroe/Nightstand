local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}

-- Layout ids are stable: they are written to disk and referenced by the
-- layout modules, so renaming one breaks existing installs.
Settings.LAYOUTS = {
    { id = "hero_grid", name = "Hero and grid" },
    { id = "shelf",     name = "Shelf stack" },
    { id = "list",      name = "List first" },
}

Settings.DEFAULTS = {
    layout = "hero_grid",
    server = "",
    username = "",
    books_dir = "",
    refresh_on_wake = true,
    captions = true,
    time_remaining = true,
    grid_cols = 4,
    grid_rows = 2,
    wifi_only = true,
    delete_when_finished = false,
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

function Settings:toggle(key)
    self:set(key, not self:get(key))
end

function Settings:layoutName()
    local current = self:get("layout")
    for _, layout in ipairs(self.LAYOUTS) do
        if layout.id == current then return layout.name end
    end
    return current
end

return Settings
