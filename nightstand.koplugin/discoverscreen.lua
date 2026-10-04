--[[--
The Discover tab: Hardcover's recommendations as a paged grid or list.

A chip row picks the list (For you, Top picks, More like the current book);
the Want to read list sits behind its own button in the header. A list row is
a small cover with title, author, rating, year, length and the start of the
description. Tapping a book opens the details sheet; long-press goes straight
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
local VerticalSpan = require("ui/widget/verticalspan")
local Background = require("background")
local BookActions = require("bookactions")
local Books = require("books")
local CoverGrid = require("covergrid")
local Dim = require("dim")
local Discover = require("discover")
local Hardcover = require("hardcover")
local NightstandScreen = require("screen")
local Rows = require("rows")
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
    view_setting = "discover_view",
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
    self:loadView()
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
    local list_h = h - title_h - (in_want and 0 or chips_h) - line - pager_h - tabs_h - tabs_margin
    if self.view == "list" then
        self.plan = Rows.plan(w, list_h)
        self.per_page = self.plan.per_page
    else
        self.plan = CoverGrid.plan(w - 2 * self.gutter, list_h - 2 * W.GAP, #self.entries)
        self.per_page = self.plan.cols * self.plan.rows
    end
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

function DiscoverScreen:titleBand(h, band_y)
    local w = self.screen_w
    local inner_w = w - 2 * self.gutter
    local data = Discover:load()
    local sep = Dim.px(18)
    local view = NightstandScreen.control(nil, self:viewLabel(), "▾")
    local right = HorizontalGroup:new{ align = "center", view }
    local view_w = view:getSize().w
    local left
    if self.list == "want" then
        left = HorizontalGroup:new{
            align = "center",
            text("‹ " .. _("Discover"), "infont", 13, GREY),
            hspan(self.gutter),
            text(_("Want to read"), SERIF, 20),
        }
        self:zone(0, band_y, w - self.gutter - view_w - sep, h,
                  function() self:showList(self.previous or "recs") end)
    else
        left = text(_("Discover"), SERIF, 20)
        local want = W.chip(T(_("Want to read (%1)"), #(data and data.lists.want or {})), false)
        local want_w = want:getSize().w
        table.insert(right, hspan(sep))
        table.insert(right, want)
        self:zone(self.gutter + inner_w - want_w - sep / 2, band_y,
                  want_w + sep / 2 + self.gutter, h, function() self:showList("want") end)
    end
    local right_w = right:getSize().w
    local view_x = self.gutter + inner_w - right_w - sep / 2
    self:zone(view_x, band_y, math.min(view_w + sep, w - view_x), h, function() self:chooseView() end)
    return LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{
            align = "center",
            hspan(self.gutter),
            LeftContainer:new{ dimen = Geom:new{ w = inner_w - right_w, h = h }, left },
            right,
        },
    }
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
    local first = (self.page - 1) * self.per_page + 1
    local tap = function(entry) self:openBook(entry) end
    local hold = function(entry) self:holdBook(entry) end
    local body
    if self.view == "list" then
        body = Rows.page(self.entries, first, self.plan, self.screen_w, band_y,
                         function(...) self:zone(...) end, tap, hold,
                         function(entry, w, rh) return Rows.row(self:rowSpec(entry), w, rh, self.gutter) end)
    else
        body = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = W.GAP },
            HorizontalGroup:new{
                hspan(self.gutter),
                CoverGrid.page(self.entries, first, self.plan, self.screen_w - 2 * self.gutter,
                               band_y + W.GAP, function(x, ...) self:zone(x + self.gutter, ...) end,
                               tap, hold),
            },
        }
    end
    return TopContainer:new{ dimen = Geom:new{ w = self.screen_w, h = h }, body }
end

--- What a list row says about a book: rating, year, length, and whether the
--- library already has it.
function DiscoverScreen:rowSpec(entry)
    local facts = {}
    if entry.rating then table.insert(facts, string.format("★ %.1f", entry.rating)) end
    if entry.year then table.insert(facts, tostring(entry.year)) end
    if entry.pages then table.insert(facts, T(_("%1 pages"), entry.pages)) end
    if entry.match then
        table.insert(facts, entry.match.on_device and _("on this device") or _("in your library"))
    elseif entry.wanted and self.list ~= "want" then
        table.insert(facts, _("want to read"))
    end
    return { cover = entry, cover_opts = { no_tag = true }, title = entry.title,
             author = entry.author, facts = facts, blurb = entry.summary }
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
    -- (columns fill top to bottom, so the page is still one contiguous range)
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
