--[[--
Nightstand's home screen: layout A, "hero and grid".

Bands, top to bottom: status strip, continue card, library header, cover
grid, pager, tab bar. Heights come from fractions of the screen so the same
code fits a 1404x1872 tablet, an 824x1648 phone and a desktop window.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Books = require("books")
local TabBar = require("tabbar")
local CoverCache = require("covercache")
local Settings = require("settings")
local Dim = require("dim")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template

-- Book titles get a serif; the chrome stays sans and the data stays mono.
local SERIF = "NotoSerif-Bold.ttf"

-- Resolved from this file so the plugin folder can live anywhere.
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
local CLOUD_ICON = PLUGIN_DIR .. "/resources/cloud-arrow-down.svg"
local CLOUD_RATIO = (640 + 64) / (512 + 64)  -- viewBox, halo included

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GREY = Blitbuffer.COLOR_GRAY

-- Fractions of screen height, from the measured design.
local BAND = {
    status = 0.034,
    hero   = 0.238,
    -- The header row is centred in this band, so its height is the gap above
    -- and below the row as well: rule, space, LIBRARY + filters, space, covers.
    head   = 0.069,
    pager  = 0.026,
    tabs   = 0.044,
}

-- Order matters: it is the order the segments appear in.
local FILTERS = {
    { id = "all",     label = "All" },
    { id = "device",  label = "On device" },
    { id = "reading", label = "Reading" },
}

local HomeScreen = InputContainer:extend{
    name = "nightstand_home",
    covers_fullscreen = true,
}

-- helpers ------------------------------------------------------------------

local function text(str, face_name, size, fg, max_width)
    return TextWidget:new{
        text = str or "",
        face = Dim.face(face_name, size),
        fgcolor = fg or BLACK,
        max_width = max_width,
    }
end

local function hspan(w) return HorizontalSpan:new{ width = w } end

local function rule(w)
    return LineWidget:new{ background = GREY, dimen = Geom:new{ w = w, h = Size.line.thin } }
end

--- A band of exactly `h` pixels, contents left-aligned with a side gutter.
local function band(w, h, gutter, inner)
    return LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{ hspan(gutter), inner },
    }
end

-- construction -------------------------------------------------------------

function HomeScreen:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.gutter = math.floor(self.screen_w * 0.023)
    self.page = self.page or 1
    self.tap_zones = {}

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = full } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = full } }
        self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = full } }
    end

    self.entries = Books:list(Settings:booksDir())
    self.current, self.fresh = Books:current(self.entries)
    self.filter = self.filter or "all"
    self:recompute()
    self:build()
end

--- Everything that depends on the active filter. Called again on refresh,
--- because build() on its own would paint a stale page count.
function HomeScreen:recompute()
    self.shown = self:visibleEntries()
    local area_w = self.screen_w - 2 * self.gutter
    local grid_h = self:gridHeight()
    self.row_gap = Dim.px(10)
    self.cols, self.cover_w, self.gap = self:metrics(area_w, 163)
    local cell_h = math.floor(self.cover_w * 1.5) + self:captionHeight()
    self.rows = math.max(1, math.floor((grid_h + self.row_gap) / (cell_h + self.row_gap)))
    self.per_page = self.cols * self.rows
    self.pages = math.max(1, math.ceil(#self.shown / self.per_page))
    if self.page > self.pages then self.page = self.pages end
end

--- How many covers fit across, and how wide each is.
--- Driven by a target cell width in device-independent units, so a 1404 px
--- tablet lands on four and an 824 px phone on three; the covers are then
--- sized to fill the row exactly, leaving only a thin gap between them.
function HomeScreen:metrics(area_w, target_dp)
    local gap = Dim.px(8)
    local cols = math.max(2, math.floor(area_w / Dim.px(target_dp) + 0.5))
    local cover_w = math.floor((area_w - (cols - 1) * gap) / cols)
    return cols, cover_w, gap
end

function HomeScreen:visibleEntries()
    if self.filter == "all" then return self.entries end
    local out = {}
    for _, entry in ipairs(self.entries) do
        local keep = (self.filter == "device" and entry.on_device)
                  or (self.filter == "reading" and entry.status == "reading")
        if keep then table.insert(out, entry) end
    end
    return out
end

function HomeScreen:setFilter(id)
    if self.filter == id then return end
    self.filter, self.page = id, 1
    self:refresh()
end

function HomeScreen:zone(x, y, w, h, callback, on_hold)
    table.insert(self.tap_zones, { rect = Geom:new{ x = x, y = y, w = w, h = h },
                                   cb = callback, hold = on_hold })
end

function HomeScreen:build()
    if Settings:get("layout") == "shelf" then
        return self:buildShelf()
    end
    return self:buildGrid()
end

--- Layout B: a tall continue card over labelled shelves of bare covers.
function HomeScreen:buildShelf()
    local w, h = self.screen_w, self.screen_h
    local status_h = Dim.px(27)
    local tabs_h = self:tabsHeight()
    local tabs_margin = self:tabsMargin()

    local all = {}
    for _, shelf in ipairs(self:shelfSource()) do
        if #shelf.books > 0 then table.insert(all, shelf) end
    end

    -- A book shows up once on the home screen: later shelves skip covers an
    -- earlier one already shows. That can empty a shelf, which changes the
    -- plan, so plan, de-duplicate, and plan again with what is left.
    local function distinct(cols)
        local seen, out = {}, {}
        for _, shelf in ipairs(all) do
            local books = {}
            for _, book in ipairs(shelf.books) do
                if not seen[book] then table.insert(books, book) end
            end
            if #books > 0 then
                for i = 1, math.min(cols, #books) do seen[books[i]] = true end
                table.insert(out, { label = shelf.label, books = books, total = #shelf.books })
            end
        end
        return out
    end

    local footer_h = tabs_h + tabs_margin
    local count, cols, cover_w, each, hero_h = self:shelfPlan(math.max(1, #all), status_h, footer_h)
    local shelves = distinct(cols)
    if #shelves < count then
        count, cols, cover_w, each, hero_h = self:shelfPlan(math.max(1, #shelves), status_h, footer_h)
        shelves = distinct(cols)
    end
    self.strip_cover_w = cover_w
    self.strip_cols = cols

    local y = 0
    local stack = VerticalGroup:new{ align = "left" }
    local function add(widget, height)
        table.insert(stack, widget)
        y = y + height
    end

    -- each rule is taken out of the band above it, so the stack sums to h
    local line = Size.line.thin
    add(self:statusBand(status_h - line), status_h - line)
    add(rule(w), line)

    local hero_y = y
    add(self:heroBand(hero_h - line, hero_y, true), hero_h - line)
    add(rule(w), line)

    for index = 1, count do
        local strip_y = y
        if shelves[index] then
            add(self:stripBand(shelves[index], each, strip_y), each)
        else
            -- a fresh install: nothing local and no catalogue fetched yet
            add(CenterContainer:new{
                dimen = Geom:new{ w = w, h = each },
                text(_("No books yet. Refresh the catalogue under Settings."), "cfont", 15, GREY),
            }, each)
        end
    end

    add(VerticalSpan:new{ width = tabs_margin }, tabs_margin)
    local tabs_y = y
    add(self:tabsBand(tabs_h, tabs_y), tabs_h)

    self[1] = FrameContainer:new{
        width = w, height = h, background = WHITE,
        bordersize = 0, padding = 0, margin = 0,
        stack,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

--- The shelves to stack under the hero; other screens built like this one
--- (Discover) supply their own.
function HomeScreen:shelfSource()
    return Books:shelves(self.entries, self.current)
end

--- The tab bar is chrome, not content: it keeps one height whatever the
--- orientation, with a fixed margin above it.
function HomeScreen:tabsHeight()
    return TabBar.height()
end

function HomeScreen:tabsMargin()
    return TabBar.margin()
end

function HomeScreen:labelHeight()
    local probe = text("Ag", "infont", 11, GREY)
    local height = probe:getSize().h
    probe:free()
    return height
end

--- Works out how many shelves, how many covers per shelf, and what is left
--- for the hero.
---
--- Shelves take exactly the height they need and the slack goes to the hero,
--- because a 2:3 cover rarely divides the space evenly. Every combination of
--- shelf count and column count is tried; a plan is valid when shelf covers
--- stay legible and the hero's cover is bigger than a shelf cover, which is
--- what keeps the continue card reading as the main thing on the screen.
--- Among valid plans the hero should take about its target share of the
--- height -- a third in portrait, half in landscape, where it was liked big --
--- and within that tolerance larger covers win. A tall phone therefore gets
--- a third shelf rather than a hero that swallows half the screen.
function HomeScreen:shelfPlan(max_count, status_h, footer_h)
    local area_w = self.screen_w - 2 * self.gutter
    local gap = Dim.px(8)
    local chrome = self:labelHeight() + Dim.pad.default + Dim.pad.large
    local available = self.screen_h - status_h - footer_h
    local smallest = Dim.px(70)
    local landscape = self.screen_w > self.screen_h
    local target = landscape and 0.5 or 0.3
    local tolerance = 0.08

    local plans = {}
    for count = 1, math.min(max_count, 4) do
        for cols = 3, 10 do
            local cover_w = math.floor((area_w - (cols - 1) * gap) / cols)
            if cover_w < smallest then break end
            local each = chrome + math.floor(cover_w * 1.5)
            local hero_h = available - count * each
            if hero_h > 0 and self:heroCoverWidth(hero_h) > cover_w then
                table.insert(plans, { count = count, cols = cols, cover_w = cover_w,
                                      each = each, hero_h = hero_h,
                                      off = math.abs(hero_h / available - target) })
            end
        end
    end

    local best
    for _, plan in ipairs(plans) do
        if plan.off <= tolerance then
            if not best or best.off > tolerance or plan.cover_w > best.cover_w then best = plan end
        elseif not best or (best.off > tolerance and plan.off < best.off) then
            best = plan
        end
    end
    if best then return best.count, best.cols, best.cover_w, best.each, best.hero_h end

    -- nothing satisfies the hero rule (a very short screen): one modest shelf
    local cover_w = math.floor((area_w - 3 * gap) / 4)
    local each = chrome + math.floor(cover_w * 1.5)
    return 1, 4, cover_w, each, math.max(0, available - each)
end

-- Kept in step with heroBand's own padding; the hero cover is sized from
-- whatever is left of the band.
local HERO_PAD = 0.05

function HomeScreen:heroCoverWidth(hero_h)
    local pad = math.floor(hero_h * HERO_PAD)
    return math.floor((hero_h - 2 * pad) / 1.5)
end

function HomeScreen:stripBand(shelf, h, band_y)
    local w = self.screen_w
    local gap = Dim.px(8)
    local cover_w = self.strip_cover_w
    local cols = self.strip_cols
    local cover_h = math.floor(cover_w * 1.5)
    local label_h = self:labelHeight()

    local header = HorizontalGroup:new{
        align = "bottom",
        text(shelf.label:upper(), "infont", 11, GREY),
        hspan(Dim.pad.default),
        text(T("(%1)", shelf.total or #shelf.books), "infont", 10, GREY),
    }

    local row = HorizontalGroup:new{ align = "top" }
    local content_h = label_h + Dim.pad.default + cover_h
    local top = band_y + math.floor((h - content_h) / 2)
    for index = 1, cols do
        local entry = shelf.books[index]
        if index > 1 then table.insert(row, hspan(gap)) end
        if entry then
            table.insert(row, self:coverTile(entry, cover_w, cover_h, false, true))
            self:zone(self.gutter + (index - 1) * (cover_w + gap),
                      top + label_h + Dim.pad.default,
                      cover_w, cover_h,
                      function() self:openBook(entry) end,
                      function() self:holdBook(entry) end)
        else
            table.insert(row, hspan(cover_w))
        end
    end

    local inner = VerticalGroup:new{ align = "left" }
    table.insert(inner, header)
    table.insert(inner, VerticalSpan:new{ width = Dim.pad.default })
    table.insert(inner, row)
    return band(w, h, self.gutter, inner)
end

--- Band heights for the grid layout; recompute() sizes the grid from the
--- same numbers build draws with, so the rows always fit.
function HomeScreen:gridHeights()
    local h = self.screen_h
    local heights = {}
    for key, fraction in pairs(BAND) do
        heights[key] = math.floor(h * fraction)
    end
    heights.tabs = self:tabsHeight()
    heights.tabs_margin = self:tabsMargin()
    heights.grid = h - heights.status - heights.hero - heights.head
                     - heights.pager - heights.tabs - heights.tabs_margin
    return heights
end

function HomeScreen:gridHeight()
    return self:gridHeights().grid
end

function HomeScreen:buildGrid()
    local w, h = self.screen_w, self.screen_h
    local heights = self:gridHeights()

    local y = 0
    local stack = VerticalGroup:new{ align = "left" }

    local function add(widget, height)
        table.insert(stack, widget)
        y = y + height
    end

    -- each rule is taken out of the band above it, so the stack sums to h
    local line = Size.line.thin
    add(self:statusBand(heights.status - line), heights.status - line)
    add(rule(w), line)

    local hero_y = y
    add(self:heroBand(heights.hero - line, hero_y), heights.hero - line)
    add(rule(w), line)

    -- Each band needs the y it starts at, so read it before add() moves on.
    local head_y = y
    add(self:headBand(heights.head, head_y), heights.head)

    local grid_y = y
    add(self:gridBand(heights.grid, grid_y), heights.grid)

    local pager_y = y
    add(self:pagerBand(heights.pager, pager_y), heights.pager)

    add(VerticalSpan:new{ width = heights.tabs_margin }, heights.tabs_margin)
    local tabs_y = y
    add(self:tabsBand(heights.tabs, tabs_y), heights.tabs)

    self[1] = FrameContainer:new{
        width = w,
        height = h,
        background = WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        stack,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

function HomeScreen:statusText()
    local server = Settings:get("server"):gsub("^https?://", "")
    if server == "" then server = _("no server set") end
    return server
end

function HomeScreen:statusBand(h)
    local right = text(os.date("%H:%M"), "infont", 13, GREY)
    local inner_w = self.screen_w - 2 * self.gutter
    -- never runs into the clock: cut with an ellipsis instead
    local left = text(self:statusText(), "infont", 13, GREY,
                      inner_w - right:getSize().w - Dim.pad.large)
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{
            hspan(self.gutter),
            LeftContainer:new{ dimen = Geom:new{ w = inner_w - right:getSize().w, h = h }, left },
            right,
        },
    }
end

function HomeScreen:heroBand(h, band_y, with_blurb)
    local entry = self.current
    local pad = math.floor(h * HERO_PAD)
    local inner_h = h - 2 * pad
    if not entry then
        local msg = Settings:get("books_dir") == ""
            and _("Set a books folder under Tools > Nightstand.")
             or _("Nothing in progress. Pick something below.")
        return band(self.screen_w, h, self.gutter,
                    CenterContainer:new{
                        dimen = Geom:new{ w = self.screen_w - 2 * self.gutter, h = h },
                        text(msg, "cfont", 17, GREY),
                    })
    end

    local cover_h = inner_h
    local cover_w = math.floor(cover_h / 1.5)
    local tile = self:coverTile(entry, cover_w, cover_h, true)
    local meta_w = self.screen_w - 2 * self.gutter - cover_w - self.gutter


    -- The column has inner_h to fill. Title, author and progress are built
    -- first; the blurb gets whatever height is left, and when even those
    -- don't fit, the least important lines go first.
    local title = TextBoxWidget:new{
        text = entry.title, face = Dim.face(SERIF, 22),
        width = meta_w, alignment = "left",
    }
    local one_line = text("Ag", SERIF, 22):getSize().h
    if title:getSize().h > 2 * one_line + 2 then
        title:free()
        title = TextBoxWidget:new{
            text = entry.title, face = Dim.face(SERIF, 22), width = meta_w, alignment = "left",
            height = 2 * one_line, height_overflow_show_ellipsis = true,
        }
    end
    local author = entry.author and entry.author ~= "" and text(entry.author, "cfont", 14, GREY, meta_w)

    local progress = self:heroDetails(entry, meta_w)

    local function height(list)
        local sum = 0
        for _, widget in ipairs(list) do sum = sum + widget:getSize().h end
        return sum
    end
    local gap = Dim.pad.default
    local fixed = Dim.pad.small + title:getSize().h + (author and author:getSize().h or 0)
                  + gap + height(progress)
    -- out of room: drop reading details from the bottom, then the author
    while fixed > inner_h and #progress > 2 do
        fixed = fixed - table.remove(progress):getSize().h
    end
    if fixed > inner_h and author then
        fixed = fixed - author:getSize().h
        author = nil
    end

    local blurb, overflows
    if with_blurb and entry.summary then
        local face = Dim.face("cfont", 13)
        local more_h = text(_("more"), "infont", 12, BLACK):getSize().h
        local line_h = text("Ag", "cfont", 13):getSize().h
        local room = inner_h - fixed - gap
        blurb = TextBoxWidget:new{
            text = entry.summary, face = face,
            width = meta_w, alignment = "left", fgcolor = GREY,
        }
        if blurb:getSize().h > room then
            blurb:free()
            -- whole lines only, and leave room for the "more" under them
            local lines = math.floor((room - more_h) / line_h)
            if lines >= 1 then
                blurb = TextBoxWidget:new{
                    text = entry.summary, face = face,
                    width = meta_w, alignment = "left", fgcolor = GREY,
                    height = lines * line_h, height_overflow_show_ellipsis = true,
                }
                overflows = true
            else
                blurb = nil
            end
        end
    end

    local meta = VerticalGroup:new{ align = "left" }
    table.insert(meta, VerticalSpan:new{ width = Dim.pad.small })
    table.insert(meta, title)
    if author then table.insert(meta, author) end
    table.insert(meta, VerticalSpan:new{ width = gap })
    if blurb then
        table.insert(meta, blurb)
        if overflows then
            self.more_widget = text(_("more"), "infont", 12, BLACK)
            table.insert(meta, self.more_widget)
        end
        table.insert(meta, VerticalSpan:new{ width = gap })
    end
    for _, widget in ipairs(progress) do table.insert(meta, widget) end

    if self.more_widget then
        -- The hero is centred in its band, and the meta column starts at the
        -- top of that centred block.
        local content_h = math.max(cover_h, meta:getSize().h)
        local top = band_y + math.floor((h - content_h) / 2)
        local offset = 0
        for _, child in ipairs(meta) do
            if child == self.more_widget then break end
            offset = offset + child:getSize().h
        end
        local size = self.more_widget:getSize()
        local summary, title = entry.summary, entry.title
        self:zone(self.gutter + cover_w + self.gutter, top + offset,
                  size.w, size.h, function() self:showBlurb(title, summary) end)
        self.more_widget = nil
    end

    self:zone(0, band_y, self.screen_w, h, function() self:openBook(entry) end,
              function() self:holdBook(entry) end)

    return band(self.screen_w, h, self.gutter,
                HorizontalGroup:new{ align = "top", tile, hspan(self.gutter), meta })
end

--- What sits under the title and author: reading progress here, rating and
--- year on Discover. A list of widgets; the last ones are dropped first when
--- the hero runs out of room.
function HomeScreen:heroDetails(entry, meta_w)
    local percent = entry.percent or 0
    local progress = {}
    if self.fresh then
        table.insert(progress, text(_("Not started"), "infont", 15, GREY))
    else
        table.insert(progress, text(string.format("%d%% read", math.floor(percent * 100 + 0.5)),
                                    "infont", 15))
        table.insert(progress, ProgressWidget:new{
            width = meta_w, height = Dim.px(7),
            percentage = percent, bordersize = 0,
            fillcolor = BLACK, bgcolor = GREY,
        })
        local parts = {}
        if entry.pages then
            table.insert(parts, T(_("page %1 of %2"),
                                  math.floor(percent * entry.pages + 0.5), entry.pages))
        end
        if entry.device then
            table.insert(parts, T(_("from %1, %2"), entry.device,
                                  os.date("%d %b %H:%M", entry.synced_at or os.time())))
        end
        if #parts > 0 then
            local joined = text(table.concat(parts, "  ·  "), "infont", 12, GREY)
            if joined:getSize().w <= meta_w then
                table.insert(progress, joined)
            else
                -- too long for one line on a narrow screen: one fact per line
                joined:free()
                for _, part in ipairs(parts) do
                    table.insert(progress, text(part, "infont", 12, GREY, meta_w))
                end
            end
        end
    end

    return progress
end

function HomeScreen:filterCell(spec, active)
    return FrameContainer:new{
        background = active and BLACK or WHITE,
        color = BLACK,
        bordersize = Size.border.thin,
        padding = Dim.pad.small,
        margin = 0,
        radius = 0,
        text(spec.label, "infont", 11, active and WHITE or BLACK),
    }
end

function HomeScreen:headBand(h, band_y)
    local strip = HorizontalGroup:new{ align = "center" }
    local widths, total = {}, 0
    for index, spec in ipairs(FILTERS) do
        local cell = self:filterCell(spec, self.filter == spec.id)
        local cell_w = cell:getSize().w
        widths[index] = cell_w
        total = total + cell_w
        table.insert(strip, cell)
    end

    local inner_w = self.screen_w - 2 * self.gutter
    local strip_x = self.gutter + inner_w - total
    local running = strip_x
    for index, spec in ipairs(FILTERS) do
        local cell_w = widths[index]
        local id = spec.id
        self:zone(running, band_y, cell_w, h, function() self:setFilter(id) end)
        running = running + cell_w
    end

    local label = text(T(_("LIBRARY  ·  %1 books"), #self.shown), "infont", 12)
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{
            align = "center",
            hspan(self.gutter),
            LeftContainer:new{ dimen = Geom:new{ w = inner_w - total, h = h }, label },
            strip,
        },
    }
end

--- Two lines of caption, measured rather than guessed: a fixed fraction of
--- the band was reserving nearly twice what the text needs.
function HomeScreen:captionHeight()
    local title = text("Ag", "cfont", 12)
    local status = text("Ag", "infont", 10)
    local total = title:getSize().h + status:getSize().h
    title:free()
    status:free()
    return total
end

function HomeScreen:gridBand(h, band_y)
    local w = self.screen_w
    local row_gap = self.row_gap
    local caption_h = self:captionHeight()
    local cover_w, gap = self.cover_w, self.gap
    local cover_h = math.floor(cover_w * 1.5)
    local cell_h = cover_h + caption_h

    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1

    for row = 1, self.rows do
        local line = HorizontalGroup:new{ align = "top" }
        for col = 1, self.cols do
            local idx = first + (row - 1) * self.cols + (col - 1)
            local entry = self.shown[idx]
            if col > 1 then table.insert(line, hspan(gap)) end
            if entry then
                local cell = VerticalGroup:new{ align = "left" }
                table.insert(cell, self:coverTile(entry, cover_w, cover_h))
                table.insert(cell, text(entry.title, SERIF, 12, BLACK, cover_w))
                table.insert(cell, text(Books:progressTag(entry), "infont", 10, GREY, cover_w))
                table.insert(line, cell)

                local x = self.gutter + (col - 1) * (cover_w + gap)
                local cy = band_y + (row - 1) * (cell_h + row_gap)
                self:zone(x, cy, cover_w, cover_h, function() self:openBook(entry) end)
            else
                table.insert(line, hspan(cover_w))
            end
        end
        table.insert(grid, line)
        if row < self.rows then
            table.insert(grid, VerticalSpan:new{ width = row_gap })
        end
    end

    return band(w, h, self.gutter, grid)
end

function HomeScreen:pagerBand(h, band_y)
    local label = T(_("‹   Page %1 of %2   ›"), self.page, self.pages)
    local widget = text(label, "infont", 12, GREY)
    local third = math.floor(self.screen_w / 3)
    self:zone(0, band_y, third, h, function() self:turnPage(-1) end)
    self:zone(2 * third, band_y, third, h, function() self:turnPage(1) end)
    return CenterContainer:new{ dimen = Geom:new{ w = self.screen_w, h = h }, widget }
end

function HomeScreen:tabsBand(h, band_y)
    return TabBar.build(self.screen_w, h, band_y, self.tab_id or "home",
                        function(...) self:zone(...) end,
                        function(id) self:onTab(id) end)
end

-- a cover, with its two corner marks ---------------------------------------

function HomeScreen:coverTile(entry, w, h, no_tag, hide_new)
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        allow_mirroring = false,
    }
    local bb = CoverCache:get(entry, w, h)
    if bb then
        table.insert(group, ImageWidget:new{
            image = bb, image_disposable = false, width = w, height = h,
        })
    else
        table.insert(group, self:placeholderCover(entry, w, h))
    end

    local pad = math.max(2, math.floor(w * 0.04))
    local tag
    if not no_tag then
        -- an entry can bring its own tag (Discover's "In library"), or none
        if entry.tag ~= nil then tag = entry.tag or nil else tag = Books:progressTag(entry) end
    end
    if tag == "New" and hide_new then tag = nil end
    if tag then
        local solid = tag ~= "New" and tag ~= "Finished"
        local badge = FrameContainer:new{
            background = solid and BLACK or WHITE,
            color = BLACK,
            bordersize = solid and 0 or Size.border.thin,
            padding = Dim.pad.tiny,
            margin = 0,
            radius = 0,
            text(tag, "infont", 10, solid and WHITE or BLACK),
        }
        badge.overlap_offset = { w - badge:getSize().w - pad, pad }
        table.insert(group, badge)
    end

    if not entry.on_device then
        -- No backdrop: the icon carries its own white halo, drawn into the
        -- SVG, so it stays readable over dark and light cover art alike.
        local icon_h = math.max(Dim.px(10), math.floor(w * 0.10))
        local badge = ImageWidget:new{
            file = CLOUD_ICON,
            width = math.floor(icon_h * CLOUD_RATIO), height = icon_h,
            scale_factor = 0,  -- keep the icon's aspect
            alpha = true,
        }
        local size = badge:getSize()
        badge.overlap_offset = { w - size.w - pad, h - size.h - pad }
        table.insert(group, badge)
    end

    return group
end

function HomeScreen:placeholderCover(entry, w, h)
    local border = Size.border.thin
    local pad = Dim.pad.small
    local inner_w = w - 2 * border - 2 * pad
    local inner_h = h - 2 * border - 2 * pad
    local function title(cap)
        return TextBoxWidget:new{
            text = entry.title, face = Dim.face(SERIF, 13),
            width = inner_w, alignment = "center",
            height = cap, height_overflow_show_ellipsis = cap ~= nil,
        }
    end
    -- a title longer than the cover is cut, not spilled; short ones stay centred
    local label = title()
    if label:getSize().h > inner_h then
        label:free()
        label = title(inner_h)
    end
    return FrameContainer:new{
        background = WHITE, color = GREY, bordersize = border,
        padding = pad, margin = 0, radius = 0,
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, label },
    }
end

-- behaviour ----------------------------------------------------------------

function HomeScreen:showBlurb(title, summary)
    UIManager:show(require("ui/widget/textviewer"):new{
        title = title,
        text = summary,
    })
end

--- Long-press on a cover; only Discover does something with it.
function HomeScreen:holdBook(_entry) end

function HomeScreen:openBook(entry)
    if entry.on_device and entry.file then
        UIManager:close(self)
        require("apps/reader/readerui"):showReader(entry.file)
    else
        self:fetchAndOpen(entry)
    end
end

function HomeScreen:fetchAndOpen(entry)
    local InfoMessage = require("ui/widget/infomessage")
    local working = InfoMessage:new{ text = T(_("Fetching %1…"), entry.title) }
    UIManager:show(working)
    UIManager:forceRePaint()

    local ok, result = require("download"):book(entry)
    UIManager:close(working)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not fetch %1.\n%2"), entry.title, tostring(result)),
        })
        self:refresh()
        return
    end
    UIManager:close(self)
    require("apps/reader/readerui"):showReader(result)
end

function HomeScreen:turnPage(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    self:refresh()
end

function HomeScreen:onTab(id)
    if id == "home" then return end
    if self.plugin then self.plugin:openTab(id) end
end

--- Re-read the books, for when the catalogue changed underneath.
function HomeScreen:reload()
    self.entries = Books:list(Settings:booksDir())
    self.current, self.fresh = Books:current(self.entries)
    self:refresh()
end

function HomeScreen:refresh()
    self.tap_zones = {}
    self.more_widget = nil
    self:recompute()
    self:build()
    UIManager:setDirty(self, "ui")
end

function HomeScreen:onTap(_, ges)
    for _index, zone in ipairs(self.tap_zones) do
        if zone.rect:contains(ges.pos) then
            zone.cb()
            return true
        end
    end
    return true
end

function HomeScreen:onHold(_, ges)
    for _index, zone in ipairs(self.tap_zones) do
        if zone.hold and zone.rect:contains(ges.pos) then
            zone.hold()
            return true
        end
    end
    return true
end

function HomeScreen:onSwipe(_, ges)
    if ges.direction == "west" then
        self:turnPage(1)
    elseif ges.direction == "east" then
        self:turnPage(-1)
    end
    return true
end

function HomeScreen:onClose()
    UIManager:close(self)
    return true
end

function HomeScreen:onCloseWidget()
    if self.on_closed then self.on_closed() end
    UIManager:setDirty(nil, "full")
end

-- shared with the other full-screen views, which extend this one
HomeScreen.SERIF = SERIF
HomeScreen.util = { text = text, hspan = hspan, rule = rule, band = band }

return HomeScreen
