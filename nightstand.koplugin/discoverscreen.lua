--[[--
The Discover tab: Hardcover's recommendations, laid out like the home screen.

A Top Pick takes the hero; below it, Want to read, Recommended for you, Top
picks and "More like" whatever is being read. Books the CWA library already
holds say so and open like any other book; the rest open a details sheet
with Want to read and a lookup at the reader's chosen shop or library.
Long-press goes straight to that lookup.
--]]--

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Books = require("books")
local Discover = require("discover")
local Hardcover = require("hardcover")
local HomeScreen = require("homescreen")
local Settings = require("settings")
local Vendors = require("vendors")
local Dim = require("dim")
local _ = require("gettext")
local T = require("ffi/util").template

local text = HomeScreen.util.text
local Blitbuffer = require("ffi/blitbuffer")
local GREY = Blitbuffer.COLOR_GRAY

local DiscoverScreen = HomeScreen:extend{
    name = "nightstand_discover",
    tab_id = "discover",
}

function DiscoverScreen:init()
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()
    self.gutter = math.floor(self.screen_w * 0.023)
    self.page = 1
    self.tap_zones = {}

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local GestureRange = require("ui/gesturerange")
        local full = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = full } }
        self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = full } }
    end

    self.library = Books:list(Settings:booksDir())
    self:collect()
    self:build()
end

--- A Hardcover book as the shared cover tile understands it.
function DiscoverScreen:entryFor(hc_id)
    local data = Discover:load()
    local book = data and data.books[hc_id]
    if not book then return nil end
    local entry = {}
    for k, v in pairs(book) do entry[k] = v end
    entry.match = Discover.match(book, self.library)
    entry.wanted = Discover:isWanted(hc_id)
    -- only a book the library holds but this device doesn't gets the cloud badge
    entry.on_device = entry.match == nil or entry.match.on_device
    entry.tag = entry.match and _("In library") or false
    return entry
end

function DiscoverScreen:collect()
    local data = Discover:load()
    self.shelves_data = {}
    self.current = nil
    if not data then return end

    local seen = {}
    local function list(ids)
        local out = {}
        for _, id in ipairs(ids or {}) do
            local entry = not seen[id] and self:entryFor(id)
            if entry then table.insert(out, entry) end
        end
        return out
    end

    -- the hero: the first Top Pick the library doesn't have yet, else any
    local top = list(data.lists.top)
    for _, entry in ipairs(top) do
        if not entry.match then self.current = entry break end
    end
    self.current = self.current or top[1]
    if self.current then seen[self.current.hc_id] = true end

    local function add(label, ids)
        local books = list(ids)
        if #books > 0 then table.insert(self.shelves_data, { label = label, books = books }) end
    end
    add(_("Want to read"), data.lists.want)
    add(_("Recommended for you"), data.lists.recs)
    if data.similar_to then add(T(_("More like %1"), data.similar_to), data.lists.similar) end
    add(_("Top picks"), data.lists.top)
end

function DiscoverScreen:shelfSource()
    return self.shelves_data
end

function DiscoverScreen:build()
    HomeScreen.build(self)
    -- the status line doubles as "fetch again"
    self:zone(0, 0, self.screen_w, Dim.px(27), function() self:fetchAgain() end)
end

function DiscoverScreen:fetchAgain()
    local NetworkMgr = require("ui/network/manager")
    local InfoMessage = require("ui/widget/infomessage")
    if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{ text = _("Not connected. Showing what was fetched last time."), timeout = 3 })
        return
    end
    local working = InfoMessage:new{ text = _("Fetching recommendations from Hardcover…") }
    UIManager:show(working)
    UIManager:forceRePaint()
    local current = Books:current(self.library)
    local ok, err = Discover:refresh(current and current.title)
    if ok then Discover:fetchCovers(12) end
    UIManager:close(working)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Could not reach Hardcover.\n%1"), tostring(err)) })
        return
    end
    self:reload()
end

function DiscoverScreen:statusText()
    local data = Discover:load()
    local who = Hardcover:username()
    local parts = { who and ("hardcover · @" .. who) or "hardcover" }
    if data and data.fetched_at then
        local today = os.date("%Y%m%d") == os.date("%Y%m%d", data.fetched_at)
        table.insert(parts, T(_("updated %1"), os.date(today and "%H:%M" or "%d %b", data.fetched_at)))
    end
    return table.concat(parts, "  ·  ")
end

function DiscoverScreen:heroDetails(entry, meta_w)
    local out = {}
    local facts = {}
    if entry.rating then table.insert(facts, string.format("★ %.1f", entry.rating)) end
    if entry.year then table.insert(facts, tostring(entry.year)) end
    if entry.pages then table.insert(facts, T(_("%1 pages"), entry.pages)) end
    if #facts > 0 then table.insert(out, text(table.concat(facts, "  ·  "), "infont", 14, nil, meta_w)) end
    local where
    if entry.match then
        where = entry.match.on_device and _("In your library, on this device") or _("In your library")
    elseif entry.wanted then
        where = _("On your Want to read list")
    else
        where = T(_("Long-press: find on %1"), Vendors.current().name)
    end
    table.insert(out, text(where, "infont", 12, GREY, meta_w))
    return out
end

-- behaviour -------------------------------------------------------------------------

function DiscoverScreen:openBook(entry)
    local lines = {}
    if entry.author ~= "" then table.insert(lines, entry.author) end
    local facts = {}
    if entry.rating then table.insert(facts, string.format("★ %.1f", entry.rating)) end
    if entry.year then table.insert(facts, tostring(entry.year)) end
    if entry.pages then table.insert(facts, T(_("%1 pages"), entry.pages)) end
    if #facts > 0 then table.insert(lines, table.concat(facts, " · ")) end
    if entry.summary then table.insert(lines, "\n" .. entry.summary) end

    local viewer
    local row = {}
    if entry.match then
        table.insert(row, {
            text = entry.match.on_device and _("Read") or _("Download and read"),
            callback = function()
                UIManager:close(viewer)
                HomeScreen.openBook(self, entry.match)
            end,
        })
    end
    table.insert(row, {
        text = entry.wanted and _("Remove from Want to read") or _("Want to read"),
        callback = function()
            UIManager:close(viewer)
            self:toggleWanted(entry)
        end,
    })
    local buttons = { row, {
        { text = T(_("Find on %1"), Vendors.current().name), callback = function()
            UIManager:close(viewer)
            Vendors.show(entry)
        end },
        { text = _("Close"), callback = function() UIManager:close(viewer) end },
    } }
    viewer = require("ui/widget/textviewer"):new{
        title = entry.title,
        text = table.concat(lines, "\n"),
        buttons_table = buttons,
    }
    UIManager:show(viewer)
end

function DiscoverScreen:holdBook(entry)
    Vendors.show(entry)
end

function DiscoverScreen:toggleWanted(entry)
    local ok, err = Discover:setWanted(entry.hc_id, not entry.wanted)
    if not ok then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = T(_("Hardcover didn't accept that.\n%1"), tostring(err)),
        })
        return
    end
    self:reload()
end

function DiscoverScreen:reload()
    self:collect()
    self:refresh()
end

function DiscoverScreen:refresh()
    self.tap_zones = {}
    self.more_widget = nil
    self:build()
    UIManager:setDirty(self, "ui")
end

function DiscoverScreen:onTab(id)
    if id == "discover" then return end
    UIManager:close(self)
    if id ~= "home" and self.plugin then self.plugin:openTab(id) end
end

function DiscoverScreen:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

--- Shown instead of the screen when nothing could be loaded.
function DiscoverScreen.emptyMessage()
    if not Hardcover:isLinked() then
        return _("Connect a Hardcover account under Settings to see recommendations.")
    end
    return _("Nothing to show yet. Connect to Wi-Fi and open Discover again to fetch recommendations.")
end

return DiscoverScreen
