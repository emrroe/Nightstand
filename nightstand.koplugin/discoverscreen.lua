--[[--
The Discover tab: Hardcover's recommendations as a paged list.

A chip row picks the list (For you, Top picks, More like the current book);
the Want to read list sits behind its own button in the header. Each row is a
small cover with title, author, rating, year, length and the start of the
description. Tapping a row opens the details sheet; long-press goes straight
to the reader's chosen shop or library. Covers for the page being shown are
fetched in the background.
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Background = require("background")
local BookActions = require("bookactions")
local Books = require("books")
local CoverTile = require("covertile")
local Dim = require("dim")
local Discover = require("discover")
local Hardcover = require("hardcover")
local NightstandScreen = require("screen")
local Settings = require("settings")
local TabBar = require("tabbar")
local Vendors = require("vendors")
local W = require("widgets")
local _ = require("gettext")
local T = require("ffi/util").template

local text, hspan, rule = W.text, W.hspan, W.rule
local BLACK, GREY, SERIF = W.BLACK, W.GREY, W.SERIF

local DiscoverScreen = NightstandScreen:extend{
    name = "nightstand_discover",
    tab_id = "discover",
    pageable = true,
}

-- the lists a chip can show; Want to read has its own button instead
local LISTS = {
    { id = "recs", label = _("For you") },
    { id = "top", label = _("Top picks") },
    { id = "similar" },  -- labelled after the book it is like
}

function DiscoverScreen:load()
    self.page = self.page or 1
    self.list = self.list or Settings:get("discover_list") or "recs"
    self.library = Books:list(Settings:booksDir())
end

--- A Hardcover book as the cover tile and the rows understand it.
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
    entry.tag = false
    return entry
end

function DiscoverScreen:items()
    local data = Discover:load()
    local out = {}
    for _index, id in ipairs(data and data.lists[self.list] or {}) do
        local entry = self:entryFor(id)
        if entry then table.insert(out, entry) end
    end
    return out
end

function DiscoverScreen:availableLists()
    local data = Discover:load() or { lists = {} }
    local out = {}
    for _index, spec in ipairs(LISTS) do
        if #(data.lists[spec.id] or {}) > 0 then
            local label = spec.label or T(_("More like %1"), data.similar_to or "")
            table.insert(out, { id = spec.id, label = label })
        end
    end
    return out
end

-- layout ------------------------------------------------------------------------

function DiscoverScreen:build()
    local w, h = self.screen_w, self.screen_h
    local title_h, chips_h, pager_h = Dim.px(46), Dim.px(36), Dim.px(26)
    local tabs_h, tabs_margin = TabBar.height(), TabBar.margin()
    local line = Size.line.thin
    local in_want = self.list == "want"

    self.entries = self:items()
    self.row_h = W.coverHeight(self:coverWidth()) + 2 * Dim.pad.large
    local list_h = h - title_h - (in_want and 0 or chips_h) - line - pager_h - tabs_h - tabs_margin
    self.per_page = math.max(1, math.floor(list_h / self.row_h))
    -- rows share the leftover height, which goes to longer descriptions
    self.row_h = math.floor(list_h / self.per_page)
    self.pages = math.max(1, math.ceil(#self.entries / self.per_page))
    if self.page > self.pages then self.page = self.pages end

    local stack = W.stack()
    stack:add(self:titleBand(title_h, stack.y), title_h)
    if not in_want then stack:add(self:chipsBand(chips_h, stack.y), chips_h) end
    stack:add(rule(w), line)
    stack:add(self:listBand(list_h, stack.y), list_h)
    stack:add(self:pagerBand(pager_h, stack.y), pager_h)
    stack:space(tabs_margin)
    stack:add(self:tabsBand(tabs_h, stack.y), tabs_h)
    self:setContent(stack.group)
    self:fetchPageCovers()
end

function DiscoverScreen:coverWidth()
    return Dim.px(72)
end

function DiscoverScreen:titleBand(h, band_y)
    local w = self.screen_w
    local inner_w = w - 2 * self.gutter
    local data = Discover:load()
    local left, right
    if self.list == "want" then
        left = HorizontalGroup:new{
            align = "center",
            text("‹ " .. _("Discover"), "infont", 13, GREY),
            hspan(self.gutter),
            text(_("Want to read"), SERIF, 20),
        }
        self:zone(0, band_y, w, h, function() self:showList(self.previous or "recs") end)
    else
        left = text(_("Discover"), SERIF, 20)
        right = W.chip(T(_("Want to read (%1)"), #(data and data.lists.want or {})), false)
        local right_w = right:getSize().w
        self:zone(self.gutter + inner_w - right_w - Dim.pad.large, band_y,
                  right_w + Dim.pad.large + self.gutter, h, function() self:showList("want") end)
    end
    local right_w = right and right:getSize().w or 0
    local row = HorizontalGroup:new{
        align = "center",
        hspan(self.gutter),
        LeftContainer:new{ dimen = Geom:new{ w = inner_w - right_w, h = h }, left },
    }
    if right then table.insert(row, right) end
    return LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, row }
end

function DiscoverScreen:chipsBand(h, band_y)
    local limit = self.screen_w - self.gutter
    local strip = HorizontalGroup:new{ align = "center" }
    local x = self.gutter
    local space = Dim.px(6)
    for index, spec in ipairs(self:availableLists()) do
        if index > 1 then
            table.insert(strip, hspan(space))
            x = x + space
        end
        local active = self.list == spec.id
        local chip = W.chip(spec.label, active)
        -- a long "More like …" on a narrow screen: shorten it to what fits
        local label = spec.label
        while x + chip:getSize().w > limit and #label > 6 do
            label = label:sub(1, #label - 4)
            chip = W.chip(label .. "…", active)
        end
        local chip_w = chip:getSize().w
        table.insert(strip, chip)
        local id = spec.id
        self:zone(x, band_y, chip_w, h, function() self:showList(id) end)
        x = x + chip_w
    end
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{ hspan(self.gutter), strip },
    }
end

function DiscoverScreen:listBand(h, band_y)
    if #self.entries == 0 then
        local message = self.list == "want"
            and _("Nothing on your Want to read list yet. Tap a book and choose Want to read.")
             or _("Nothing here yet.")
        return CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = h },
            TextBoxWidget:new{ text = message, face = Dim.face("cfont", 14), fgcolor = GREY,
                               width = self.screen_w - 4 * self.gutter, alignment = "center" },
        }
    end
    local list = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1
    local y = band_y
    for i = first, math.min(#self.entries, first + self.per_page - 1) do
        local entry = self.entries[i]
        table.insert(list, self:row(entry, self.row_h))
        self:zone(0, y, self.screen_w, self.row_h, function() self:openBook(entry) end,
                  function() self:holdBook(entry) end)
        y = y + self.row_h
    end
    return TopContainer:new{ dimen = Geom:new{ w = self.screen_w, h = h }, list }
end

--- One book: its cover, then title, author, the facts line, and as much of
--- the description as fits beside the cover.
function DiscoverScreen:row(entry, h)
    local cover_w = self:coverWidth()
    local cover_h = W.coverHeight(cover_w)
    local text_w = self.screen_w - 2 * self.gutter - cover_w - self.gutter
    local col = VerticalGroup:new{ align = "left" }
    local used = 0
    local function put(widget)
        table.insert(col, widget)
        used = used + widget:getSize().h
    end
    put(text(entry.title, SERIF, 15, BLACK, text_w))
    if entry.author ~= "" then put(text(entry.author, "cfont", 12, GREY, text_w)) end
    local facts = {}
    if entry.rating then table.insert(facts, string.format("★ %.1f", entry.rating)) end
    if entry.year then table.insert(facts, tostring(entry.year)) end
    if entry.pages then table.insert(facts, T(_("%1 pages"), entry.pages)) end
    if entry.match then
        table.insert(facts, entry.match.on_device and _("on this device") or _("in your library"))
    elseif entry.wanted and self.list ~= "want" then
        table.insert(facts, _("want to read"))
    end
    if #facts > 0 then put(text(table.concat(facts, "  ·  "), "infont", 11, BLACK, text_w)) end
    local line_h = W.lineHeight("cfont", 12)
    local room = h - 2 * Dim.pad.large - Size.line.thin - used
    if entry.summary and room >= line_h then
        put(TextBoxWidget:new{
            text = entry.summary, face = Dim.face("cfont", 12), fgcolor = GREY, width = text_w,
            height = math.floor(room / line_h) * line_h, height_overflow_show_ellipsis = true,
        })
    end

    local line = Size.line.thin
    return VerticalGroup:new{
        align = "left",
        LeftContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = h - line },
            HorizontalGroup:new{
                align = "top",
                hspan(self.gutter),
                CoverTile.new(entry, cover_w, cover_h, { no_tag = true }),
                hspan(self.gutter),
                col,
            },
        },
        rule(self.screen_w),
    }
end

--- Page arrows either side; the middle refreshes from Hardcover.
function DiscoverScreen:pagerBand(h, band_y)
    local third = math.floor(self.screen_w / 3)
    local label = self:updatedLabel()
    if self.pages > 1 then
        label = T(_("‹   %1 of %2   ›"), self.page, self.pages) .. "     " .. label
        self:zone(0, band_y, third, h, function() self:turnPage(-1) end)
        self:zone(2 * third, band_y, third, h, function() self:turnPage(1) end)
    end
    self:zone(third, band_y, third, h, function() self:fetchAgain() end)
    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        text(label, "infont", 12, GREY),
    }
end

function DiscoverScreen:updatedLabel()
    local data = Discover:load()
    if not data or not data.fetched_at then return "↻" end
    local today = os.date("%Y%m%d") == os.date("%Y%m%d", data.fetched_at)
    return T(_("updated %1 ↻"), os.date(today and "%H:%M" or "%d %b", data.fetched_at))
end

-- behaviour -------------------------------------------------------------------------

function DiscoverScreen:showList(id)
    if id == self.list then return end
    if id == "want" then self.previous = self.list end
    self.list, self.page = id, 1
    if id ~= "want" then Settings:set("discover_list", id) end
    self:refresh()
end

function DiscoverScreen:onTabAgain()
    if self.list == "want" then self:showList(self.previous or "recs") end
end

function DiscoverScreen:onClose()
    if self.list == "want" then
        self:showList(self.previous or "recs")
        return true
    end
    return NightstandScreen.onClose(self)
end

function DiscoverScreen:turnPage(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    self:refresh()
end

--- Covers for the rows on screen, fetched after the page is drawn.
function DiscoverScreen:fetchPageCovers()
    if not require("net").mayDownload() then return end
    local first = (self.page - 1) * self.per_page + 1
    local missing = {}
    for i = first, math.min(#self.entries, first + self.per_page - 1) do
        local entry = self.entries[i]
        if entry.image_url and not Discover:hasCover(entry.hc_id, entry.image_url) then
            table.insert(missing, entry)
        end
    end
    if #missing == 0 then return end
    local page, list = self.page, self.list
    Background.run(missing, function(entry) Discover:fetchCover(entry) end, {
        on_done = function()
            if self.page == page and self.list == list and UIManager:isWidgetShown(self) then
                self:refresh()
            end
        end,
    })
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
    UIManager:close(working)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Could not reach Hardcover.\n%1"), tostring(err)) })
        return
    end
    self:reload()
end

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
                BookActions.open(self, entry.match)
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
    viewer = require("ui/widget/textviewer"):new{
        title = entry.title,
        text = table.concat(lines, "\n"),
        buttons_table = { row, {
            { text = T(_("Find on %1"), Vendors.current().name), callback = function()
                UIManager:close(viewer)
                Vendors.show(entry)
            end },
            { text = _("Close"), callback = function() UIManager:close(viewer) end },
        } },
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

--- Shown instead of the screen when nothing could be loaded.
function DiscoverScreen.emptyMessage()
    if not Hardcover:isLinked() then
        return _("Connect a Hardcover account under Settings to see recommendations.")
    end
    return _("Nothing to show yet. Connect to Wi-Fi and open Discover again to fetch recommendations.")
end

return DiscoverScreen
