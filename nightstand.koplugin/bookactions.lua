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
        -- open where Home said the book is: another device's newer position
        if entry.remote then require("syncguard").seed(entry.file, entry.remote, true) end
        return showReader(entry.file)
    end
    if not Net.mayDownload() then
        return message(_("This phone is on mobile data and “Over Wi-Fi only” is on. Connect to Wi-Fi, or turn that off in Settings."))
    end
    Net.whenOnline(function() download(screen, entry) end)
end

local function pct(p) return math.floor((p or 0) * 100 + 0.5) end

--- Where the reader stands in a book, as one line.
function BookActions.progressLine(entry)
    if entry.status == "complete" then return _("Finished") end
    if not require("books").started(entry) then return _("Not started") end
    local line = T(_("%1% read"), pct(entry.percent))
    if entry.device then
        local when = entry.synced_at and os.date("%d %b", entry.synced_at)
        line = line .. " · " .. entry.device .. (when and (", " .. when) or "")
    end
    return line
end

--- The short facts a sheet shows under the title and author.
function BookActions.facts(entry)
    local facts = {}
    if entry.series and entry.series_index then
        local n = entry.series_index
        table.insert(facts, T(_("Book %1 of %2"), n == math.floor(n) and string.format("%d", n) or n,
                              entry.series))
    end
    table.insert(facts, BookActions.progressLine(entry))
    local year = type(entry.published) == "string" and entry.published:match("^(%d%d%d%d)")
    local where = entry.on_device and _("On this device") or _("Not downloaded")
    table.insert(facts, year and (where .. " · " .. year) or where)
    return facts
end

local function hasPositions(entry)
    return #require("progress"):positions(entry) > 0
end

--- Long-press on a book, on Home and in the Library: one menu everywhere.
function BookActions.hold(screen, entry)
    local dialog
    local function button(text, fn)
        return {{ text = text, align = "left", callback = function()
            UIManager:close(dialog)
            fn()
        end }}
    end
    local buttons = {
        button(entry.on_device and _("Open") or _("Download and open"),
               function() BookActions.open(screen, entry) end),
        button(_("Details"), function() BookActions.details(screen, entry) end),
    }
    if hasPositions(entry) then
        table.insert(buttons, button(_("Previous reading positions…"),
                                     function() BookActions.positions(screen, entry) end))
    end
    if entry.on_device and entry.file then
        table.insert(buttons, button(_("Remove from this device"), function() BookActions.remove(screen, entry) end))
    end
    dialog = require("ui/widget/buttondialog"):new{ title = entry.title, title_align = "center",
                                                    buttons = buttons }
    UIManager:show(dialog)
end

--- Positions the book was read to before, on any device, to go back to --
--- for when one was overwritten by mistake.
function BookActions.positions(screen, entry)
    local dialog
    local buttons = {}
    for index, record in ipairs(require("progress"):positions(entry)) do
        if index > 8 then break end
        local when = record.timestamp and os.date("%d %b %H:%M", record.timestamp) or "?"
        table.insert(buttons, {{
            text = T(_("%1% · %2 · %3"), pct(record.percentage), record.device or "?", when),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                BookActions.restore(screen, entry, record)
            end,
        }})
    end
    if #buttons == 0 then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("No earlier positions of this book are known yet."), timeout = 3 })
        return
    end
    dialog = require("ui/widget/buttondialog"):new{
        title = T(_("Go back to an earlier position in %1"), entry.title), title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- The book's details, with what can be done with it.
function BookActions.details(screen, entry)
    local rows = {{
        { text = entry.on_device and _("Read") or _("Download and read"),
          callback = function() BookActions.open(screen, entry) end },
    }}
    if hasPositions(entry) then
        table.insert(rows[1], { text = _("Earlier positions…"),
                                callback = function() BookActions.positions(screen, entry) end })
    end
    local second = {}
    if entry.on_device and entry.file then
        table.insert(second, { text = _("Remove from device"), callback = function() BookActions.remove(screen, entry) end })
    end
    table.insert(second, { text = T(_("Find on %1"), require("vendors").current().name),
                           callback = function() require("vendors").show(entry) end })
    table.insert(rows, second)
    UIManager:show(require("booksheet"):new{
        entry = entry, title = entry.title, author = entry.author,
        facts = BookActions.facts(entry), description = entry.summary, buttons = rows,
    })
end

--- Delete the book's file from this device. A book the server also holds
--- keeps its settings (position, highlights), ready for a new download; a
--- book only this device had is gone for good, so it is asked about as such.
function BookActions.remove(screen, entry)
    local on_server = entry.book_id ~= nil
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = on_server
            and T(_("Remove \"%1\" from this device?\n\nIt stays on your server, and your position and highlights are kept for when you download it again."), entry.title)
             or T(_("Delete \"%1\"?\n\nThis book is only on this device, so it will be gone for good, with its highlights."), entry.title),
        ok_text = on_server and _("Remove") or _("Delete"),
        ok_callback = function()
            local file = entry.file
            if not on_server then
                pcall(function() require("docsettings"):open(file):purge() end)
            end
            local ok, err = os.remove(file)
            if not ok then
                UIManager:show(require("ui/widget/infomessage"):new{ text = T(_("Could not remove it: %1"), tostring(err)) })
                return
            end
            pcall(function() require("readhistory"):removeItemByPath(file) end)
            require("availability"):invalidate()
            if screen and screen.reload then screen:reload() end
        end,
    })
end

--- Open `entry` at `record`'s position; the reader then saves it as the latest.
function BookActions.restore(screen, entry, record)
    if entry.on_device and entry.file then
        -- going back on purpose: newer positions elsewhere are not a question
        require("syncguard").seed(entry.file, record, true, os.time())
    else
        require("progress"):choose(entry.book_id, record)
    end
    BookActions.open(screen, entry)
end

return BookActions
