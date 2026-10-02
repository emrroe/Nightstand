--[[--
Opening a book from any screen: straight away when it is on the device,
otherwise fetched from the server first.
--]]--

local UIManager = require("ui/uimanager")
local Net = require("net")
local _ = require("gettext")
local T = require("ffi/util").template

local BookActions = {}

local function message(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

local function showReader(file)
    require("screen").closeAll()
    require("apps/reader/readerui"):showReader(file)
end

local function download(screen, entry)
    local working = require("ui/widget/infomessage"):new{ text = T(_("Fetching %1…"), entry.title) }
    UIManager:show(working)
    UIManager:forceRePaint()
    local ok, result = require("download"):book(entry)
    UIManager:close(working)
    if not ok then
        message(T(_("Could not fetch %1.\n%2"), entry.title, tostring(result)))
        screen:refresh()
        return
    end
    showReader(result)
end

--- Open `entry` from `screen`, which closes once the reader takes over.
function BookActions.open(screen, entry)
    if entry.on_device and entry.file then
        return showReader(entry.file)
    end
    if not Net.mayDownload() then
        return message(_("This phone is on mobile data and “Over Wi-Fi only” is on. Connect to Wi-Fi, or turn that off in Settings."))
    end
    Net.whenOnline(function() download(screen, entry) end)
end

return BookActions
