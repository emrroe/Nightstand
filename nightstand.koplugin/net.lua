--[[--
Network questions the screens ask before doing something expensive.
--]]--

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local Settings = require("settings")

local Net = {}

--- True only when the device is sure it is on mobile data; e-readers and
--- desktops have no such thing.
function Net.onMobileData()
    if not Device:isAndroid() then return false end
    local ok, result = pcall(function()
        local android = require("android")
        local C = require("ffi").C
        local _, kind = android.getNetworkInfo()
        return tonumber(kind) == C.ANETWORK_MOBILE
    end)
    return ok and result or false
end

--- Large transfers (books, covers) respect "Over Wi-Fi only".
function Net.mayDownload()
    return not (Settings:get("wifi_only") and Net.onMobileData())
end

function Net.isOnline()
    return NetworkMgr:isOnline()
end

--- Run `fn` once online; turns Wi-Fi on first if the device's setting allows.
function Net.whenOnline(fn)
    NetworkMgr:runWhenOnline(fn)
end

return Net
