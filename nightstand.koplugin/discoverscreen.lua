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
local Dialogs = require("dialogs")
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
local MUTED, BOLD, REGULAR = W.MUTED, W.BOLD, W.REGULAR

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
    local title_h, tabs_h, pager_h = Dim.px(42), Dim.px(34), Dim.px(30)
    local tabs_bar_h, tabs_margin = TabBar.height(), TabBar.margin()
    local line = Size.line.thin
    local in_want = self.list == "want"

    self.entries = self:items()
    local list_h = h - title_h - (in_want and line or tabs_h) - pager_h - tabs_bar_h - tabs_margin
    if self.view == "list" then
        self.plan = Rows.plan(w, list_h)
        self.per_page = self.plan.per_page
    else
        self.plan = CoverGrid.plan(w - 2 * self.gutter, list_h - 2 * W.GAP)
        self.per_page = self.plan.cols * self.plan.rows
    end
    self.pages = math.max(1, math.ceil(#self.entries / self.per_page))
    if self.page > self.pages then self.page = self.pages end

    local stack = W.stack()
    stack:add(self:titleBand(title_h, stack.y), title_h)
    if in_want then
        stack:add(rule(w), line)
    else
        stack:add(self:listTabs(tabs_h, stack.y), tabs_h)
    end
    stack:add(self:listBand(list_h, stack.y), list_h)
    stack:add(self:pagerBand(pager_h, stack.y, self:updatedLabel()), pager_h)
    stack:space(tabs_margin)
    stack:add(self:tabsBand(tabs_bar_h, stack.y), tabs_bar_h)
    self:setContent(stack.group)
    self:fetchPageCovers()
end

--- "Discover" with the view dropdown and the Want to read count on the
--- right; inside Want to read, "‹ Want to read" and the way back.
--- "Discover" with the view dropdown, the Want to read count and refresh
--- on the right; inside Want to read, "‹ Want to read" and the way back.
function DiscoverScreen:titleBand(h, band_y)
    local w = self.screen_w
    local data = Discover:load()
    local sep = Dim.px(16)
    local items = { { widget = W.dropdown(self:viewLabel()), on_tap = function() self:chooseView() end } }
    local left
    if self.list == "want" then
        left = HorizontalGroup:new{
            align = "center",
            W.icon("chevron-left", 20),
            hspan(Dim.pad.small),
            text(_("Want to read"), BOLD, 21),
        }
    else
        left = text(_("Discover"), BOLD, 21)
        table.insert(items, {
            widget = HorizontalGroup:new{
                align = "center",
                W.icon("bookmark-on", 17),
                hspan(Dim.pad.small),
                text(tostring(#(data and data.lists.want or {})), BOLD, 12),
            },
            on_tap = function() self:showList("want") end,
        })
    end
    table.insert(items, { widget = W.icon("refresh", 20), on_tap = function() self:fetchAgain() end })

    local right = HorizontalGroup:new{ align = "center" }
    local widths, right_w = {}, 0
    for index, item in ipairs(items) do
        widths[index] = item.widget:getSize().w
        if index > 1 then
            table.insert(right, hspan(sep))
            right_w = right_w + sep
        end
        table.insert(right, item.widget)
        right_w = right_w + widths[index]
    end
    local x = w - self.gutter - right_w
    if self.list == "want" then
        self:zone(0, band_y, x - sep / 2, h, function() self:showList(self.previous or "recs") end)
    end
    for index, item in ipairs(items) do
        local last = index == #items
        self:zone(x - sep / 2, band_y, widths[index] + sep / 2 + (last and self.gutter or sep / 2), h, item.on_tap)
        x = x + widths[index] + sep
    end
    return LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{
            align = "center",
            hspan(self.gutter),
            LeftContainer:new{ dimen = Geom:new{ w = w - 2 * self.gutter - right_w, h = h }, left },
            right,
        },
    }
end

function DiscoverScreen:listTabs(h, band_y)
    local tabs = {}
    for _index, spec in ipairs(self:availableLists()) do
        local id = spec.id
        table.insert(tabs, { label = spec.label, active = self.list == id,
                             on_tap = function() self:showList(id) end })
    end
    return self:tabRow(h, band_y, tabs)
end

function DiscoverScreen:listBand(h, band_y)
    if #self.entries == 0 then
        if self.list == "want" then
            return self:emptyState(self.screen_w, h, band_y, "bookmark-on",
                _("Nothing on your Want to read list yet. Tap a book and choose Want to read."),
                _("Back to Discover"), function() self:showList(self.previous or "recs") end)
        end
        return self:emptyState(self.screen_w, h, band_y, "tab-discover-on",
            _("No suggestions here yet."), _("Refresh"), function() self:fetchAgain() end)
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

function DiscoverScreen:updatedLabel()
    local data = Discover:load()
    if not data or not data.fetched_at then return _("refresh") end
    local today = os.date("%Y%m%d") == os.date("%Y%m%d", data.fetched_at)
    return T(_("updated %1"), os.date(today and "%H:%M" or "%d %b", data.fetched_at))
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
    if not NetworkMgr:isOnline() then
        Dialogs.note(_("Not connected. Showing what was fetched last time."))
        return
    end
    local working = Dialogs.working(_("Fetching recommendations from Hardcover…"))
    local current = Books:current(self.library)
    local ok, err = Discover:refresh(current and current.title)
    if ok then Discover:markFinished(self.library) end
    UIManager:close(working)
    if not ok then
        Dialogs.note(T(_("Could not reach Hardcover.\n%1"), tostring(err)))
        return
    end
    self:reload()
end

--- The book's details over the list, with its cover, and what can be done
--- with it: read it when the library has it, put it on or take it off the
--- Want to read list, mark it read or unread on Hardcover, or find it.
function DiscoverScreen:openBook(entry)
    local facts = {}
    local numbers = {}
    if entry.rating then table.insert(numbers, string.format("★ %.1f", entry.rating)) end
    if entry.year then table.insert(numbers, tostring(entry.year)) end
    if entry.pages then table.insert(numbers, T(_("%1 pages"), entry.pages)) end
    if #numbers > 0 then table.insert(facts, table.concat(numbers, " · ")) end
    local status = Discover:status(entry.hc_id)
    if status == Discover.READ then
        table.insert(facts, _("Read"))
    elseif entry.wanted then
        table.insert(facts, _("On your Want to read list"))
    end
    if entry.match then
        table.insert(facts, entry.match.on_device and _("On this device") or _("In your library"))
    end

    local rows = { {} }
    if entry.match then
        table.insert(rows[1], { text = entry.match.on_device and _("Read") or _("Download and read"),
                                callback = function() BookActions.open(self, entry.match) end })
    end
    table.insert(rows[1], { text = entry.wanted and _("Remove from Want to read") or _("Want to read"),
                            callback = function() self:setStatus(entry, not entry.wanted and Discover.WANT or nil) end })
    rows[2] = {
        { text = status == Discover.READ and _("Mark as unread") or _("Mark as read"),
          callback = function() self:setStatus(entry, status ~= Discover.READ and Discover.READ or nil) end },
    }
    -- a shop only helps for a book the library does not have
    if not entry.match then
        table.insert(rows[2], { text = T(_("Find on %1"), Vendors.current().name),
                                callback = function() Vendors.show(entry) end })
    end
    UIManager:show(require("booksheet"):new{
        entry = entry, title = entry.title, author = entry.author,
        facts = facts, description = entry.summary, buttons = rows,
    })
end

function DiscoverScreen:holdBook(entry)
    -- a book the library has opens its details instead of a shop
    if entry.match then return self:openBook(entry) end
    Vendors.show(entry)
end

--- Change the book's shelf on Hardcover, then show the change.
function DiscoverScreen:setStatus(entry, status)
    local ok, err = Discover:setStatus(entry.hc_id, status)
    if not ok then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = T(_("Hardcover didn't accept that.\n%1"), tostring(err)),
        })
        return
    end
    self:reload()
end

function DiscoverScreen:toggleWanted(entry)
    self:setStatus(entry, not entry.wanted and Discover.WANT or nil)
end

--- Shown instead of the screen when nothing could be loaded.
function DiscoverScreen.emptyMessage()
    if not Hardcover:isLinked() then
        return _("Connect a Hardcover account under Settings to see recommendations.")
    end
    return _("Nothing to show yet. Connect to Wi-Fi and open Discover again to fetch recommendations.")
end

return DiscoverScreen
