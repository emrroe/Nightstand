--[[--
Runs once per KOReader start: brings settings from other plugins over, and
switches off the sync plugins Nightstand now replaces.

The CWA server and login come from the CWA sync plugin when Nightstand has
none of its own, and a KOReader sync account from KOReader's own sync
plugin, so nothing keeps depending on either. Those two are then switched
off -- once, so a reader who turns one back on in the plugin list keeps it.
--]]--

local Settings = require("settings")
local lfs = require("libs/libkoreader-lfs")

local Setup = { SYNC_PLUGINS = { "cwasync", "kosync" } }

local function installed(name)
    local DataStorage = require("datastorage")
    for _index, dir in ipairs({ DataStorage:getDataDir() .. "/plugins", "plugins" }) do
        if lfs.attributes(dir .. "/" .. name .. ".koplugin", "mode") == "directory" then return true end
    end
    return false
end

--- Bring the CWA and sync logins over, and choose where positions sync.
function Setup.adopt()
    local cwa = G_reader_settings:readSetting("cwasync") or {}
    if Settings:get("server") == "" and type(cwa.server) == "string" and cwa.server ~= "" then
        Settings:set("server", cwa.server)
    end
    if Settings:get("username") == "" and type(cwa.username) == "string" and type(cwa.password) == "string"
       and cwa.password ~= "" then
        Settings:set("username", cwa.username)
        Settings:set("password", cwa.password)
    end
    if Settings:get("sync_service") ~= nil then return end
    local ko = G_reader_settings:readSetting("kosync") or {}
    if Settings:get("server") ~= "" then
        Settings:set("sync_service", "cwa")
    elseif type(ko.username) == "string" and type(ko.userkey) == "string" then
        Settings:set("sync_username", ko.username)
        Settings:set("sync_userkey", ko.userkey)
        if type(ko.custom_server) == "string" and ko.custom_server ~= "" then
            Settings:set("sync_url", ko.custom_server)
            Settings:set("sync_service", "custom")
        else
            Settings:set("sync_service", "public")
        end
    else
        Settings:set("sync_service", "off")
    end
end

--- Switch the other sync plugins off, once Nightstand syncs itself, and only
--- once. Returns the names of those that were running, which only stop after
--- a restart.
function Setup.retireSyncPlugins()
    if Settings:get("sync_plugins_retired") or not require("syncserver").enabled() then return {} end
    Settings:set("sync_plugins_retired", true)
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    local running = {}
    for _index, name in ipairs(Setup.SYNC_PLUGINS) do
        if not disabled[name] then
            disabled[name] = true
            -- KOReader's own sync ships with every install but only runs when signed in
            local ko = name == "kosync" and G_reader_settings:readSetting("kosync")
            if (name == "cwasync" and installed(name)) or (ko and ko.userkey) then
                table.insert(running, name)
            end
        end
    end
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    return running
end

--- Everything above, at most once per start. Returns the plugins that need
--- a restart to stop.
function Setup.run()
    if Setup.ran then return {} end
    Setup.ran = true
    Setup.adopt()
    return Setup.retireSyncPlugins()
end

--- A server entered where there was none: positions sync through it, unless
--- the reader already chose another sync server.
function Setup.serverAdded()
    if Settings:get("sync_service") == "off" or Settings:get("sync_service") == nil then
        Settings:set("sync_service", "cwa")
    end
end

--- True while another sync plugin still runs in this reader, so Nightstand
--- does not save positions twice until KOReader restarts.
function Setup.otherSyncRunning(ui)
    if ui.cwasync then return true end
    local ko = ui.kosync and G_reader_settings:readSetting("kosync")
    return ko ~= nil and ko ~= false and ko.userkey ~= nil
end

return Setup
