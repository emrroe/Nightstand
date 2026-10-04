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
    pcall(require("syncguard").seedDownload, entry, result)
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

--- Long-press on a book: open it, or go back to a position it was read to
--- before, on any device -- for when one was overwritten by mistake.
function BookActions.hold(screen, entry)
    local Progress = require("progress")
    local positions = Progress:positions(entry)
    if #positions == 0 then return end
    local dialog
    local buttons = {{{
        text = entry.on_device and _("Open") or _("Download and open"),
        callback = function()
            UIManager:close(dialog)
            BookActions.open(screen, entry)
        end,
    }}}
    for index, record in ipairs(positions) do
        if index > 5 then break end
        local when = record.timestamp and os.date("%d %b %H:%M", record.timestamp) or "?"
        table.insert(buttons, {{
            text = T(_("Go back to %1% · %2 · %3"), math.floor(record.percentage * 100 + 0.5),
                     record.device or "?", when),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                BookActions.restore(screen, entry, record)
            end,
        }})
    end
    dialog = require("ui/widget/buttondialog"):new{ title = entry.title, title_align = "center",
                                                    buttons = buttons }
    UIManager:show(dialog)
end

--- Open `entry` at `record`'s position; the reader then saves it as the latest.
function BookActions.restore(screen, entry, record)
    if entry.on_device and entry.file then
        require("syncguard").seed(entry.file, record, true)
    else
        require("progress"):choose(entry.book_id, record)
    end
    BookActions.open(screen, entry)
end

return BookActions
