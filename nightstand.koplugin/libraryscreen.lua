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
local BLACK, MUTED, BOLD, REGULAR = W.BLACK, W.MUTED, W.BOLD, W.REGULAR

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

--- Books whose title, author or series contains `query`, any case.
local function matching(entries, query)
    local needle = query:lower()
    local out = {}
    for _index, entry in ipairs(entries) do
        local hay = table.concat({ entry.title or "", entry.author or "", entry.series or "" }, "\n"):lower()
        if hay:find(needle, 1, true) then table.insert(out, entry) end
    end
    return out
end

function LibraryScreen:recompute()
    local filtered = Library.filter(self.entries, self.filter)
    self.groups = Library.groups(filtered, self.group, self.sort, self.descending)

    if self.query then
        -- a search looks through everything, whatever the filter or grouping
        self.groups = nil
        self.items = Library.sort(matching(self.entries, self.query), self.sort, self.descending)
        self.showing_groups = false
    elseif self.groups and self.open_group then
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
    local above = self:headerHeight()
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

function LibraryScreen:titleHeight() return Dim.px(42) end
function LibraryScreen:controlsHeight() return Dim.px(30) end
function LibraryScreen:tabsHeight() return Dim.px(34) end
function LibraryScreen:pagerHeight() return Dim.px(30) end

--- Title, dropdowns, and the filter tabs -- which an opened group, showing
--- all of itself whatever the filter, goes without.
function LibraryScreen:headerHeight()
    return self:titleHeight() + self:controlsHeight()
           + (self:narrowed() and Size.line.thin or self:tabsHeight())
end

--- Showing one group or a search: no filter tabs, and Back widens again.
function LibraryScreen:narrowed()
    return self.open_group ~= nil or self.query ~= nil
end

-- layout ------------------------------------------------------------------------

function LibraryScreen:build()
    self:recompute()
    local stack = W.stack()
    stack:add(self:titleBand(self:titleHeight(), stack.y), self:titleHeight())
    stack:add(self:controlsBand(self:controlsHeight(), stack.y), self:controlsHeight())
    if self:narrowed() then
        stack:add(rule(self.screen_w), Size.line.thin)
    else
        stack:add(self:filterTabs(self:tabsHeight(), stack.y), self:tabsHeight())
    end
    stack:add(self:content(self.content_h, stack.y), self.content_h)
    if self.with_pager then
        stack:add(self:pagerBand(self:pagerHeight(), stack.y), self:pagerHeight())
    end
    stack:space(TabBar.margin())
    stack:add(self:tabsBand(TabBar.height(), stack.y), TabBar.height())
    self:setContent(stack.group)
end

--- "Library  21 books", or in an opened group "‹ <its name>  3 books" with
--- the whole row as the way back.
function LibraryScreen:titleBand(h, band_y)
    local inner_w = self.screen_w - 2 * self.gutter
    local row = HorizontalGroup:new{ align = "center" }
    local count = text(self:countLabel(), REGULAR, 11, MUTED)
    local count_w = count:getSize().w + Dim.pad.large
    if self:narrowed() then
        local back = W.icon("chevron-left", 20)
        local name = self.query and T("“%1”", self.query) or self.open_group
        table.insert(row, back)
        table.insert(row, hspan(Dim.pad.small))
        table.insert(row, text(name, BOLD, 20, BLACK,
                               inner_w - back:getSize().w - Dim.pad.small - count_w))
        self:zone(0, band_y, self.screen_w, h, function() self:widen() end)
    else
        table.insert(row, text(_("Library"), BOLD, 21, BLACK))
    end
    table.insert(row, hspan(Dim.pad.large))
    table.insert(row, count)
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{ align = "center", hspan(self.gutter), row },
    }
end

--- View and Show on the left, Sort on the right; a long sort name gives way
--- to its short form on a narrow screen.
function LibraryScreen:controlsBand(h, band_y)
    local sort = Library.find(Library.SORTS, self.sort)
    local show = Library.find(Library.GROUPS, self.group)
    local arrow = self.descending and "arrow-down" or "arrow-up"
    local left = { { widget = W.dropdown(self:viewLabel()), on_tap = function() self:chooseView() end } }
    if not self:narrowed() then
        table.insert(left, { widget = W.dropdown(show.label), on_tap = function() self:chooseGroup() end })
    end
    local used = 0
    for _index, c in ipairs(left) do used = used + c.widget:getSize().w + Dim.px(18) end
    local sort_widget = W.dropdown(sort.label, arrow)
    if self.gutter * 2 + used + sort_widget:getSize().w > self.screen_w then
        sort_widget:free()
        sort_widget = W.dropdown(sort.short or sort.label, arrow)
    end
    return self:controlRow(h, band_y, left, { widget = sort_widget, on_tap = function() self:chooseSort() end })
end

function LibraryScreen:countLabel()
    if self.showing_groups then
        local label = Library.find(Library.GROUPS, self.group).label:lower()
        return T("%1 %2", #self.items, label)
    end
    return bookCount(#self.items)
end

function LibraryScreen:filterTabs(h, band_y)
    local tabs = {}
    for _index, spec in ipairs(Library.FILTERS) do
        local id = spec.id
        table.insert(tabs, { label = spec.label, active = self.filter == id,
                             on_tap = function() self:setFilter(id) end })
    end
    return self:tabRow(h, band_y, tabs)
end

function LibraryScreen:content(h, band_y)
    if #self.items == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = h },
            text(_("Nothing matches this filter."), REGULAR, 14, MUTED),
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

--- Back out of an opened group, or out of a search to where it started.
function LibraryScreen:widen()
    if self.query and not self.open_group then return UIManager:close(self) end
    self:closeGroup()
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
    if self.query then
        self.query, self.open_group, self.page = nil, nil, 1
        return self:refresh()
    end
    if self.open_group then self:closeGroup() end
end

function LibraryScreen:onClose()
    if self:narrowed() then
        self:widen()
        return true
    end
    UIManager:close(self)
    return true
end

return LibraryScreen
