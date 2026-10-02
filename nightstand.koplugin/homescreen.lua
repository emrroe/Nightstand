--[[--
Nightstand's home screen: the book being read, over shelves of covers.

Bands, top to bottom: status strip, hero (the continue card), shelves, tab
bar. Discover reuses this layout with its own hero and shelves.
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Books = require("books")
local NightstandScreen = require("screen")
local TabBar = require("tabbar")
local CoverTile = require("covertile")
local Settings = require("settings")
local Dim = require("dim")
local _ = require("gettext")
local T = require("ffi/util").template

local W = require("widgets")
local text, hspan, rule, band = W.text, W.hspan, W.rule, W.band
local BLACK, WHITE, GREY, SERIF = W.BLACK, W.WHITE, W.GREY, W.SERIF

local HomeScreen = NightstandScreen:extend{
    name = "nightstand_home",
    tab_id = "home",
}

function HomeScreen:load()
    self.entries = Books:list(Settings:booksDir())
    self.current, self.fresh = Books:current(self.entries)
end

--- A tall continue card over labelled shelves of bare covers.
function HomeScreen:build()
    local w, h = self.screen_w, self.screen_h
    local status_h = W.STATUS_H
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

    self:setContent(stack)
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
    return W.lineHeight("infont", 11)
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
    local gap = W.GAP
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
            local each = chrome + W.coverHeight(cover_w)
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
    local each = chrome + W.coverHeight(cover_w)
    return 1, 4, cover_w, each, math.max(0, available - each)
end

-- Kept in step with heroBand's own padding; the hero cover is sized from
-- whatever is left of the band.
local HERO_PAD = 0.05

function HomeScreen:heroCoverWidth(hero_h)
    local pad = math.floor(hero_h * HERO_PAD)
    return math.floor((hero_h - 2 * pad) / W.COVER_ASPECT)
end

function HomeScreen:stripBand(shelf, h, band_y)
    local w = self.screen_w
    local gap = W.GAP
    local cover_w = self.strip_cover_w
    local cols = self.strip_cols
    local cover_h = W.coverHeight(cover_w)
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
            table.insert(row, CoverTile.new(entry, cover_w, cover_h, { hide_new = true }))
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

function HomeScreen:statusText()
    local server = Settings:get("server"):gsub("^https?://", "")
    if server == "" then server = _("no server set") end
    local busy = require("background").status()
    return busy and (server .. "  ·  " .. busy) or server
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

function HomeScreen:heroEmpty(h)
    local msg = Settings:get("books_dir") == ""
        and _("Set a books folder under Tools > Nightstand.")
         or _("Nothing in progress. Pick something below.")
    return band(self.screen_w, h, self.gutter, CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w - 2 * self.gutter, h = h },
        text(msg, "cfont", 17, GREY),
    })
end

--- The title in the hero's serif, two lines at most.
function HomeScreen:heroTitle(entry, w)
    local face = Dim.face(SERIF, 22)
    local title = TextBoxWidget:new{ text = entry.title, face = face, width = w, alignment = "left" }
    local two_lines = 2 * W.lineHeight(SERIF, 22)
    if title:getSize().h <= two_lines + 2 then return title end
    title:free()
    return TextBoxWidget:new{
        text = entry.title, face = face, width = w, alignment = "left",
        height = two_lines, height_overflow_show_ellipsis = true,
    }
end

--- The blurb, cut to whole lines that fit `room`, plus a "more" link when
--- it was cut. Either can be nil.
function HomeScreen:heroBlurb(entry, w, room)
    if not entry.summary then return nil end
    local face = Dim.face("cfont", 13)
    local blurb = TextBoxWidget:new{
        text = entry.summary, face = face, width = w, alignment = "left", fgcolor = GREY,
    }
    if blurb:getSize().h <= room then return blurb end
    blurb:free()
    local more = text(_("more"), "infont", 12, BLACK)
    local lines = math.floor((room - more:getSize().h) / W.lineHeight("cfont", 13))
    if lines < 1 then
        more:free()
        return nil
    end
    return TextBoxWidget:new{
        text = entry.summary, face = face, width = w, alignment = "left", fgcolor = GREY,
        height = lines * W.lineHeight("cfont", 13), height_overflow_show_ellipsis = true,
    }, more
end

--- The continue card: cover on the left, a column of text on the right that
--- fills the band. Title, author and details are placed first; the blurb gets
--- what is left, and when even that runs out the least important lines go.
function HomeScreen:heroBand(h, band_y, with_blurb)
    local entry = self.current
    if not entry then return self:heroEmpty(h) end

    local pad = math.floor(h * HERO_PAD)
    local inner_h = h - 2 * pad
    local cover_h = inner_h
    local cover_w = math.floor(cover_h / W.COVER_ASPECT)
    local tile = CoverTile.new(entry, cover_w, cover_h, { no_tag = true })
    local meta_x = self.gutter + cover_w + self.gutter
    local meta_w = self.screen_w - meta_x - self.gutter
    local gap = Dim.pad.default

    local title = self:heroTitle(entry, meta_w)
    local author = entry.author and entry.author ~= "" and text(entry.author, "cfont", 14, GREY, meta_w) or nil
    local details = self:heroDetails(entry, meta_w)

    local function heights(list)
        local sum = 0
        for _, widget in ipairs(list) do sum = sum + widget:getSize().h end
        return sum
    end
    local used = Dim.pad.small + title:getSize().h + (author and author:getSize().h or 0)
                 + gap + heights(details)
    while used > inner_h and #details > 2 do
        used = used - table.remove(details):getSize().h
    end
    if used > inner_h and author then
        used = used - author:getSize().h
        author = nil
    end

    local blurb, more
    if with_blurb then blurb, more = self:heroBlurb(entry, meta_w, inner_h - used - gap) end

    -- offsets are summed here: asking the group mid-build would freeze its layout
    local meta = VerticalGroup:new{ align = "left" }
    local meta_h = 0
    local function put(widget)
        table.insert(meta, widget)
        meta_h = meta_h + widget:getSize().h
    end
    put(VerticalSpan:new{ width = Dim.pad.small })
    put(title)
    if author then put(author) end
    put(VerticalSpan:new{ width = gap })
    local more_offset
    if blurb then
        put(blurb)
        if more then
            more_offset = meta_h
            put(more)
        end
        put(VerticalSpan:new{ width = gap })
    end
    for _, widget in ipairs(details) do put(widget) end

    if more then
        -- the hero block is centred in its band; "more" sits more_offset below its top
        local top = band_y + math.floor((h - math.max(cover_h, meta_h)) / 2)
        local size = more:getSize()
        self:zone(meta_x, top + more_offset, size.w, size.h,
                  function() self:showBlurb(entry.title, entry.summary) end)
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

-- behaviour ----------------------------------------------------------------

function HomeScreen:showBlurb(title, summary)
    UIManager:show(require("ui/widget/textviewer"):new{
        title = title,
        text = summary,
    })
end

return HomeScreen
