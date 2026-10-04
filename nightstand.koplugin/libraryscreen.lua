--[[--
The Library tab: every book, as a paged cover grid or list.

Top to bottom: a title row carrying the "view", "show" and "sort" controls, a
row of filter chips, the books, the pager and the tabs. "Show" swaps the books
for a list of authors, series or genres; tapping one opens it. View, filter,
sort and grouping are remembered between visits.
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Books = require("books")
local CoverGrid = require("covergrid")
local NightstandScreen = require("screen")
local Rows = require("rows")
local Library = require("library")
local Settings = require("settings")
local TabBar = require("tabbar")
local Dim = require("dim")
local _ = require("gettext")
local T = require("ffi/util").template

local W = require("widgets")
local text, hspan, rule = W.text, W.hspan, W.rule
local BLACK, GREY, SERIF = W.BLACK, W.GREY, W.SERIF

local function bookCount(n)
    return n == 1 and _("1 book") or T(_("%1 books"), n)
end

local LibraryScreen = NightstandScreen:extend{
    name = "nightstand_library",
    tab_id = "library",
    pageable = true,
    view_setting = "library_view",
}

function LibraryScreen:load()
    self.page = self.page or 1
    self.entries = Books:list(Settings:booksDir())
    self.filter = Library.find(Library.FILTERS, Settings:get("library_filter")).id
    self.group = Library.find(Library.GROUPS, Settings:get("library_group")).id
    local sort = Library.find(Library.SORTS, Settings:get("library_sort"))
    self.sort = sort.id
    self:loadView()
    self.descending = Settings:get("library_descending")
    if self.descending == nil then self.descending = sort.desc or false end
end

-- what is on screen -----------------------------------------------------------

function LibraryScreen:recompute()
    local filtered = Library.filter(self.entries, self.filter)
    self.groups = Library.groups(filtered, self.group, self.sort, self.descending)

    if self.groups and self.open_group then
        -- an opened series shows all of it, whatever the filter
        self.items = {}
        local all = Library.groups(self.entries, self.group, self.sort, self.descending)
        for _index, group in ipairs(all) do
            if group.name == self.open_group then self.items = group.books end
        end
        self.showing_groups = false
    elseif self.groups then
        self.items = self.groups
        self.showing_groups = true
    else
        self.items = Library.sort(filtered, self.sort, self.descending)
        self.showing_groups = false
    end

    -- the pager only takes room when there is more than one page
    local above = self:titleHeight() + self:chipsHeight() + Size.line.thin
    local below = TabBar.height() + TabBar.margin()
    self.with_pager = false
    self:planContent(self.screen_h - above - below)
    if self.pages > 1 then
        self.with_pager = true
        self:planContent(self.screen_h - above - below - self:pagerHeight())
    end
    if self.page > self.pages then self.page = self.pages end
end

--- Groups are always a list -- a series is its name, not its first cover.
function LibraryScreen:listing()
    return self.showing_groups or self.view == "list"
end

function LibraryScreen:planContent(h)
    self.content_h = h
    if self:listing() then
        self.plan = Rows.plan(self.screen_w, h)
    else
        local gap = W.GAP
        self.plan = CoverGrid.plan(self.screen_w - 2 * self.gutter, h - 2 * gap, #self.items)
        self.plan.top = gap
    end
    self.per_page = self.plan.per_page or self.plan.cols * self.plan.rows
    self.pages = math.max(1, math.ceil(#self.items / self.per_page))
end

function LibraryScreen:titleHeight() return Dim.px(46) end
function LibraryScreen:chipsHeight() return Dim.px(36) end
function LibraryScreen:pagerHeight() return Dim.px(26) end

-- layout ------------------------------------------------------------------------

function LibraryScreen:build()
    self:recompute()
    local stack = W.stack()
    stack:add(self:titleBand(self:titleHeight(), stack.y), self:titleHeight())
    stack:add(self:chipsBand(self:chipsHeight(), stack.y), self:chipsHeight())
    stack:add(rule(self.screen_w), Size.line.thin)
    stack:add(self:content(self.content_h, stack.y), self.content_h)
    if self.with_pager then
        stack:add(self:pagerBand(self:pagerHeight(), stack.y), self:pagerHeight())
    end
    stack:space(TabBar.margin())
    stack:add(self:tabsBand(TabBar.height(), stack.y), TabBar.height())
    self:setContent(stack.group)
end

function LibraryScreen:titleBand(h, band_y)
    local w = self.screen_w
    local inner_w = w - 2 * self.gutter
    local control = NightstandScreen.control

    local sort = Library.find(Library.SORTS, self.sort)
    local show = Library.find(Library.GROUPS, self.group)
    local arrow = self.descending and "↓" or "↑"
    local sep = Dim.px(18)
    local title_w = W.text(_("Library"), SERIF, 20):getSize().w

    -- On a narrow screen the header gives way in steps: first the count, then
    -- the grey "View"/"Show"/"Sort" words, then the long sort name.
    local steps = {
        { count = true, labels = true, short = false },
        { count = false, labels = true, short = false },
        { count = false, labels = false, short = false },
        { count = false, labels = false, short = true },
    }
    local fit, controls
    for _index, step in ipairs(steps) do
        fit = step
        local sort_label = step.short and (sort.short or sort.label) or sort.label
        controls = {
            { widget = control(step.labels and _("View") or nil, self:viewLabel(), "▾"),
              pick = function() self:chooseView() end },
            { widget = control(step.labels and _("Sort") or nil, sort_label, arrow),
              pick = function() self:chooseSort() end },
        }
        if not self.open_group then
            table.insert(controls, 2, {
                widget = control(step.labels and _("Show") or nil, show.label, "▾"),
                pick = function() self:chooseGroup() end })
        end
        local need = title_w
        if step.count then
            need = need + Dim.pad.large + W.text(self:countLabel(), "infont", 12):getSize().w
        end
        for _index2, c in ipairs(controls) do need = need + sep + c.widget:getSize().w end
        if need <= inner_w then break end
    end
    local right = HorizontalGroup:new{ align = "center" }
    local right_w = 0
    for index, c in ipairs(controls) do
        if index > 1 then
            table.insert(right, hspan(sep))
            right_w = right_w + sep
        end
        table.insert(right, c.widget)
        c.x = right_w
        right_w = right_w + c.widget:getSize().w
    end

    local left
    if self.open_group then
        left = text("‹ " .. show.label, SERIF, 20, GREY)
    else
        left = HorizontalGroup:new{ align = "center", text(_("Library"), SERIF, 20) }
        if fit.count then
            table.insert(left, hspan(Dim.pad.large))
            table.insert(left, text(self:countLabel(), "infont", 12, GREY))
        end
    end

    -- generous tap targets: the full band height, plus half the gap either side
    local x0 = self.gutter + inner_w - right_w
    for index, c in ipairs(controls) do
        local cw = c.widget:getSize().w
        local extra = index == #controls and self.gutter or sep / 2
        self:zone(x0 + c.x - sep / 2, band_y, cw + sep / 2 + extra, h, c.pick)
    end
    if self.open_group then
        self:zone(0, band_y, x0 - sep, h, function() self:closeGroup() end)
    end

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

function LibraryScreen:countLabel()
    if self.showing_groups then
        local label = Library.find(Library.GROUPS, self.group).label:lower()
        return T("%1 %2", #self.items, label)
    end
    return bookCount(#self.items)
end

function LibraryScreen:chipsBand(h, band_y)
    if self.open_group then return self:groupNameBand(h, band_y) end
    local strip = HorizontalGroup:new{ align = "center" }
    local x = self.gutter
    local space = Dim.px(6)
    for index, spec in ipairs(Library.FILTERS) do
        if index > 1 then
            table.insert(strip, hspan(space))
            x = x + space
        end
        local cell = W.chip(spec.label, self.filter == spec.id)
        local cell_w = cell:getSize().w
        table.insert(strip, cell)
        local id = spec.id
        self:zone(x, band_y, cell_w, h, function() self:setFilter(id) end)
        x = x + cell_w
    end
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{ hspan(self.gutter), strip },
    }
end

--- In place of the filters while a group is open: its name and size.
function LibraryScreen:groupNameBand(h, band_y)
    local inner_w = self.screen_w - 2 * self.gutter
    local count = text(bookCount(#self.items), "infont", 12, GREY)
    local name_w = inner_w - count:getSize().w - Dim.pad.large
    self:zone(0, band_y, self.screen_w, h, function() self:closeGroup() end)
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{
            align = "center",
            hspan(self.gutter),
            text(self.open_group, SERIF, 17, BLACK, name_w),
            hspan(Dim.pad.large),
            count,
        },
    }
end

function LibraryScreen:content(h, band_y)
    if #self.items == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = h },
            text(_("Nothing matches this filter."), "cfont", 15, GREY),
        }
    end
    local first = (self.page - 1) * self.per_page + 1
    local zone = function(...) self:zone(...) end
    local tap = function(item) self:activate(item) end
    local body
    if self:listing() then
        body = Rows.page(self.items, first, self.plan, self.screen_w, band_y, zone, tap, nil,
                         function(item, w, rh) return Rows.row(self:rowSpec(item), w, rh, self.gutter) end)
    else
        body = HorizontalGroup:new{
            hspan(self.gutter),
            CoverGrid.page(self.items, first, self.plan, self.screen_w - 2 * self.gutter,
                           band_y + self.plan.top,
                           function(x, ...) self:zone(x + self.gutter, ...) end, tap),
        }
        body = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = self.plan.top }, body }
    end
    return TopContainer:new{ dimen = Geom:new{ w = self.screen_w, h = h }, body }
end

local function seriesNumber(n)
    return n == math.floor(n) and string.format("%d", n) or tostring(n)
end

--- What a list row says about a book, or about a series, author or genre.
function LibraryScreen:rowSpec(item)
    if self.showing_groups then
        local read, reading, titles = 0, 0, {}
        for _index, book in ipairs(item.books) do
            if book.status == "complete" then read = read + 1 end
            if book.status == "reading" then reading = reading + 1 end
            table.insert(titles, book.title)
        end
        local facts = { bookCount(#item.books) }
        if reading > 0 then table.insert(facts, T(_("%1 reading"), reading)) end
        if read > 0 then table.insert(facts, T(_("%1 finished"), read)) end
        return { cover = item.books[1], cover_opts = { no_tag = true }, title = item.name,
                 facts = facts, blurb = table.concat(titles, "  ·  ") }
    end
    local facts = {}
    if item.series and item.series_index then
        if self.open_group and self.group == "series" then
            table.insert(facts, T(_("Book %1"), seriesNumber(item.series_index)))
        else
            table.insert(facts, T(_("%1, book %2"), item.series, seriesNumber(item.series_index)))
        end
    end
    local tag, kind = Books:progressTag(item)
    if kind ~= "new" then table.insert(facts, tag) end
    local year = type(item.published) == "string" and item.published:match("^(%d%d%d%d)")
    if year then table.insert(facts, year) end
    if not item.on_device then table.insert(facts, _("not downloaded")) end
    return { cover = item, cover_opts = { no_tag = true }, title = item.title,
             author = item.author, facts = facts, blurb = item.summary }
end

function LibraryScreen:pagerBand(h, band_y)
    if self.pages <= 1 then return VerticalSpan:new{ width = h } end
    local label = T(_("‹   Page %1 of %2   ›"), self.page, self.pages)
    local widget = text(label, "infont", 12, GREY)
    local third = math.floor(self.screen_w / 3)
    self:zone(0, band_y, third, h, function() self:turnPage(-1) end)
    self:zone(2 * third, band_y, third, h, function() self:turnPage(1) end)
    return CenterContainer:new{ dimen = Geom:new{ w = self.screen_w, h = h }, widget }
end

function LibraryScreen:turnPage(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    self:refresh()
end

function LibraryScreen:onSwipe(_, ges)
    if ges.direction == "west" then
        self:turnPage(1)
    elseif ges.direction == "east" then
        self:turnPage(-1)
    end
    return true
end

-- behaviour ---------------------------------------------------------------------

function LibraryScreen:activate(item)
    if self.showing_groups then
        self.open_group, self.page = item.name, 1
        return self:refresh()
    end
    self:openBook(item)
end

function LibraryScreen:closeGroup()
    self.open_group, self.page = nil, 1
    self:refresh()
end

function LibraryScreen:setFilter(id)
    if self.filter == id then return end
    self.filter, self.page = id, 1
    Settings:set("library_filter", id)
    self:refresh()
end

function LibraryScreen:chooseSort()
    local mark = self.descending and "   ↓" or "   ↑"
    -- picking the active sort again flips its direction
    NightstandScreen.menu(_("Sort by"), Library.SORTS, self.sort, function(spec)
        if spec.id == self.sort then
            self.descending = not self.descending
        else
            self.sort, self.descending = spec.id, spec.desc or false
        end
        Settings:set("library_sort", self.sort)
        Settings:set("library_descending", self.descending)
        self.page = 1
        self:refresh()
    end, mark)
end

function LibraryScreen:chooseGroup()
    NightstandScreen.menu(_("Show"), Library.GROUPS, self.group, function(spec)
        if spec.id == self.group and not self.open_group then return end
        self.group, self.open_group, self.page = spec.id, nil, 1
        Settings:set("library_group", spec.id)
        self:refresh()
    end)
end

function LibraryScreen:onTabAgain()
    if self.open_group then self:closeGroup() end
end

function LibraryScreen:onClose()
    if self.open_group then
        self:closeGroup()
        return true
    end
    UIManager:close(self)
    return true
end

return LibraryScreen
