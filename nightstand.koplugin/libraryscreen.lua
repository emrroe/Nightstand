--[[--
The Library tab: every book, as a paged cover grid.

Top to bottom: a title row carrying the "show" and "sort" controls, a row of
filter chips, the grid, the pager and the tabs. "Show" swaps the books for
author, series or genre tiles; tapping a tile opens that group. Filter, sort
and grouping are remembered between visits.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Books = require("books")
local CoverTile = require("covertile")
local HomeScreen = require("homescreen")
local Library = require("library")
local Settings = require("settings")
local TabBar = require("tabbar")
local Dim = require("dim")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template

local W = require("widgets")
local text, hspan, rule = W.text, W.hspan, W.rule
local BLACK, GREY, SERIF = W.BLACK, W.GREY, W.SERIF

local function bookCount(n)
    return n == 1 and _("1 book") or T(_("%1 books"), n)
end

local LibraryScreen = HomeScreen:extend{
    name = "nightstand_library",
}

function LibraryScreen:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.gutter = W.gutter(self.screen_w)
    self.page = 1
    self.tap_zones = {}

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local GestureRange = require("ui/gesturerange")
        local full = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = full } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = full } }
    end

    self.entries = Books:list(Settings:booksDir())
    self.filter = Library.find(Library.FILTERS, Settings:get("library_filter")).id
    self.group = Library.find(Library.GROUPS, Settings:get("library_group")).id
    local sort = Library.find(Library.SORTS, Settings:get("library_sort"))
    self.sort = sort.id
    self.descending = Settings:get("library_descending")
    if self.descending == nil then self.descending = sort.desc or false end
    self.open_group = nil  -- name of the group drilled into, if any

    self:recompute()
    self:build()
end

-- what is on screen -----------------------------------------------------------

function LibraryScreen:recompute()
    local filtered = Library.filter(self.entries, self.filter)
    self.groups = Library.groups(filtered, self.group, self.sort, self.descending)

    if self.groups and self.open_group then
        self.items = {}
        for _, group in ipairs(self.groups) do
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

    self.grid_h = self.screen_h - self:titleHeight() - self:chipsHeight()
                  - self:pagerHeight() - TabBar.height() - TabBar.margin()
    self:planGrid(self.grid_h - Size.line.thin - Dim.px(10))
    self.per_page = self.cols * self.rows
    self.pages = math.max(1, math.ceil(#self.items / self.per_page))
    if self.page > self.pages then self.page = self.pages end
end

--- Rows and columns for the grid. For each row count the height sets the
--- largest cover; the width then fits either one column more (covers shrink
--- to meet both margins) or one fewer (covers keep their height, the row is
--- centred). The plan showing the most books wins, as long as covers stay at
--- a legible physical size; leftover height is shared between the rows.
function LibraryScreen:planGrid(grid_h)
    local area_w = self.screen_w - 2 * self.gutter
    local gap = W.GAP
    local min_gap = Dim.px(10)
    local caption_h = self:captionHeight()
    -- about 21 mm on any screen; thinner than that and covers stop reading
    local smallest = Dim.px(100)
    local best
    local function consider(rows, cols, cover_w)
        if cols < 2 or cover_w < smallest then return end
        local used = rows * (W.coverHeight(cover_w) + caption_h) + (rows - 1) * min_gap
        local count = rows * cols
        if not best or count > best.count or (count == best.count and used > best.used) then
            best = { rows = rows, cols = cols, cover_w = cover_w, used = used, count = count }
        end
    end
    for rows = 1, 6 do
        local cover_h = math.floor((grid_h - (rows - 1) * min_gap) / rows) - caption_h
        local widest = math.floor(cover_h / W.COVER_ASPECT)
        if widest < smallest then break end
        local fit = (area_w + gap) / (widest + gap)
        local more = math.ceil(fit)
        consider(rows, more, math.floor((area_w - (more - 1) * gap) / more))
        local fewer = math.floor(fit)
        consider(rows, fewer, math.min(widest, math.floor((area_w - (fewer - 1) * gap) / fewer)))
    end
    best = best or { rows = 1, cols = 2,
                     cover_w = math.floor((area_w - gap) / 2), used = grid_h }
    self.rows, self.cols, self.cover_w, self.gap = best.rows, best.cols, best.cover_w, gap
    local row_w = best.cols * best.cover_w + (best.cols - 1) * gap
    self.grid_x = self.gutter + math.floor((area_w - row_w) / 2)
    local slack = math.max(0, grid_h - best.used)
    self.row_gap = min_gap + (best.rows > 1 and math.floor(slack / (best.rows - 1)) or 0)
end

function LibraryScreen:titleHeight() return Dim.px(46) end
function LibraryScreen:chipsHeight() return Dim.px(36) end
function LibraryScreen:pagerHeight() return Dim.px(26) end

-- layout ------------------------------------------------------------------------

function LibraryScreen:build()
    local w, h = self.screen_w, self.screen_h
    local y = 0
    local stack = VerticalGroup:new{ align = "left" }
    local function add(widget, height)
        table.insert(stack, widget)
        y = y + height
    end

    add(self:titleBand(self:titleHeight(), y), self:titleHeight())
    add(self:chipsBand(self:chipsHeight(), y), self:chipsHeight())
    local top_gap = Dim.px(10)
    add(rule(w), Size.line.thin)
    add(VerticalSpan:new{ width = top_gap }, top_gap)

    local grid_h = self.grid_h - Size.line.thin - top_gap
    add(self:libraryGrid(grid_h, y), grid_h)
    add(self:pagerBand(self:pagerHeight(), y), self:pagerHeight())

    add(VerticalSpan:new{ width = TabBar.margin() }, TabBar.margin())
    add(TabBar.build(w, TabBar.height(), y, "library",
                     function(...) self:zone(...) end,
                     function(id) self:onTab(id) end), TabBar.height())

    self[1] = W.fullscreen(w, h, stack)
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

--- A control that opens a menu: label, value, and a mark saying what it does.
function LibraryScreen:control(label, value, mark)
    return HorizontalGroup:new{
        align = "center",
        text(label, "infont", 11, GREY),
        hspan(Dim.pad.large),
        text(value .. " " .. mark, "infont", 12, BLACK),
    }
end

function LibraryScreen:titleBand(h, band_y)
    local w = self.screen_w
    local inner_w = w - 2 * self.gutter

    local sort = Library.find(Library.SORTS, self.sort)
    local show = Library.find(Library.GROUPS, self.group)
    local sort_c = self:control(_("Sort"), sort.label, self.descending and "↓" or "↑")
    local show_c = self:control(_("Show"), show.label, "▾")
    local sep = Dim.px(20)
    local sort_w, show_w = sort_c:getSize().w, show_c:getSize().w
    local right_w = show_w + sep + sort_w

    local left
    if self.open_group then
        local back = text("‹ " .. show.label, "infont", 13, GREY)
        local room = math.max(Dim.px(40), inner_w - right_w - sep - back:getSize().w - self.gutter)
        left = HorizontalGroup:new{
            align = "center",
            back,
            hspan(self.gutter),
            text(self.open_group, SERIF, 20, BLACK, room),
        }
    else
        left = HorizontalGroup:new{
            align = "center",
            text(_("Library"), SERIF, 20),
            hspan(Dim.pad.large),
            text(self:countLabel(), "infont", 12, GREY),
        }
    end

    -- generous tap targets: the full band height, plus half the gap either side
    local x = self.gutter + inner_w - right_w
    self:zone(x - sep / 2, band_y, show_w + sep, h, function() self:chooseGroup() end)
    self:zone(x + show_w + sep / 2, band_y, sort_w + sep / 2 + self.gutter, h,
              function() self:chooseSort() end)
    if self.open_group then
        self:zone(0, band_y, x - sep, h, function() self:closeGroup() end)
    end

    return LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{
            align = "center",
            hspan(self.gutter),
            LeftContainer:new{ dimen = Geom:new{ w = inner_w - right_w, h = h }, left },
            show_c, hspan(sep), sort_c,
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

function LibraryScreen:libraryGrid(h, band_y)
    if #self.items == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = h },
            text(_("Nothing matches this filter."), "cfont", 15, GREY),
        }
    end

    local caption_h = self:captionHeight()
    local cover_w, gap = self.cover_w, self.gap
    local cover_h = W.coverHeight(cover_w)
    local cell_h = cover_h + caption_h
    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1

    for row = 1, self.rows do
        local line = HorizontalGroup:new{ align = "top" }
        for col = 1, self.cols do
            local item = self.items[first + (row - 1) * self.cols + (col - 1)]
            if col > 1 then table.insert(line, hspan(gap)) end
            if item then
                table.insert(line, self:cell(item, cover_w, cover_h))
                local x = self.grid_x + (col - 1) * (cover_w + gap)
                local cy = band_y + (row - 1) * (cell_h + self.row_gap)
                self:zone(x, cy, cover_w, cell_h, function() self:activate(item) end)
            else
                table.insert(line, hspan(cover_w))
            end
        end
        table.insert(grid, line)
        if row < self.rows then
            table.insert(grid, VerticalSpan:new{ width = self.row_gap })
        end
    end

    -- top-aligned, so a short last page doesn't float in the middle
    return TopContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{ align = "top", hspan(self.grid_x), grid },
    }
end

function LibraryScreen:cell(item, cover_w, cover_h)
    local cell = VerticalGroup:new{ align = "left" }
    if self.showing_groups then
        -- a group shows its first book's cover; for a series that is book one
        table.insert(cell, CoverTile.new(item.books[1], cover_w, cover_h, { no_tag = true }))
        table.insert(cell, text(item.name, SERIF, 12, BLACK, cover_w))
        table.insert(cell, text(bookCount(#item.books), "infont", 10, GREY, cover_w))
    else
        table.insert(cell, CoverTile.new(item, cover_w, cover_h))
        table.insert(cell, text(item.title, SERIF, 12, BLACK, cover_w))
        local second = item.author ~= "" and item.author or Books:progressTag(item)
        if self.open_group and self.group == "series" and item.series_index then
            local n = item.series_index
            second = T(_("Book %1"), n == math.floor(n) and string.format("%d", n) or tostring(n))
        end
        table.insert(cell, text(second, "infont", 10, GREY, cover_w))
    end
    return cell
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

function LibraryScreen:refresh()
    self.tap_zones = {}
    self:recompute()
    self:build()
    UIManager:setDirty(self, "ui")
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

--- A menu of options; picking the active sort again flips its direction.
function LibraryScreen:menu(title, list, current, on_pick, mark)
    local buttons = {}
    local dialog
    for _, spec in ipairs(list) do
        local label = spec.label
        if spec.id == current then label = "✓  " .. label .. (mark or "") end
        table.insert(buttons, {{
            text = label,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                on_pick(spec)
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function LibraryScreen:chooseSort()
    local mark = self.descending and "   ↓" or "   ↑"
    self:menu(_("Sort by"), Library.SORTS, self.sort, function(spec)
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
    self:menu(_("Show"), Library.GROUPS, self.group, function(spec)
        if spec.id == self.group and not self.open_group then return end
        self.group, self.open_group, self.page = spec.id, nil, 1
        Settings:set("library_group", spec.id)
        self:refresh()
    end)
end

function LibraryScreen:onTab(id)
    if id == "library" then
        if self.open_group then self:closeGroup() end
        return
    end
    UIManager:close(self)
    if id ~= "home" and self.plugin then self.plugin:openTab(id) end
end

function LibraryScreen:onClose()
    if self.open_group then
        self:closeGroup()
        return true
    end
    UIManager:close(self)
    return true
end

function LibraryScreen:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

return LibraryScreen
