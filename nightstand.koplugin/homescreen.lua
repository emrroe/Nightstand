--[[--
Nightstand's home screen: the book being read, over shelves of covers.

Bands, top to bottom: status strip, hero (the continue card), shelves, tab
bar. Discover reuses this layout with its own hero and shelves.
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
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
local BLACK, MUTED, BOLD, REGULAR = W.BLACK, W.MUTED, W.BOLD, W.REGULAR

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
    for _index, shelf in ipairs(self:shelfSource()) do
        if #shelf.books > 0 then table.insert(all, shelf) end
    end

    -- A book shows up once on the home screen: later shelves skip covers an
    -- earlier one already shows. That can empty a shelf, which changes the
    -- plan, so plan, de-duplicate, and plan again with what is left.
    local function distinct(cols)
        local seen, out = {}, {}
        for _index, shelf in ipairs(all) do
            local books = {}
            for _index, book in ipairs(shelf.books) do
                if not seen[book] then table.insert(books, book) end
            end
            if #books > 0 then
                for i = 1, math.min(cols, #books) do seen[books[i]] = true end
                table.insert(out, { label = shelf.label, books = books, total = #shelf.books,
                                   see_all = shelf.see_all })
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
                text(_("No books yet. Refresh the catalogue under Settings."), REGULAR, 14, MUTED),
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
    return Books:shelves(self.entries, self.current, self:wantedBooks())
end

--- Library books on the Hardcover Want to read list, not yet finished.
function HomeScreen:wantedBooks()
    local Discover = require("discover")
    local data = require("hardcover"):isLinked() and Discover:load()
    if not data then return nil end
    local out = {}
    for _index, id in ipairs(data.lists.want or {}) do
        local book = data.books[id]
        local entry = book and Discover.match(book, self.entries)
        if entry and entry.status ~= "complete" and not Books.started(entry) then
            table.insert(out, entry)
        end
    end
    return out
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
    return W.lineHeight(BOLD, 14.5)
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
    for _index, plan in ipairs(plans) do
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

--- "Recently added 21" on the left, "See all ›" on the right when the
--- Library can show the whole shelf.
function HomeScreen:shelfHeader(shelf, band_y)
    local inner_w = self.screen_w - 2 * self.gutter
    local label_h = self:labelHeight()
    local left = HorizontalGroup:new{
        align = "bottom",
        text(shelf.label, BOLD, 14.5, BLACK),
        hspan(Dim.pad.default),
        text(tostring(shelf.total or #shelf.books), REGULAR, 11, MUTED),
    }
    local row = HorizontalGroup:new{ align = "center" }
    if shelf.see_all then
        local more = text(_("See all ›"), REGULAR, 11, MUTED)
        local more_w = more:getSize().w
        table.insert(row, LeftContainer:new{ dimen = Geom:new{ w = inner_w - more_w, h = label_h }, left })
        table.insert(row, more)
        local target = shelf.see_all
        self:zone(self.screen_w - self.gutter - more_w - Dim.pad.large, band_y - Dim.pad.default,
                  more_w + Dim.pad.large + self.gutter, label_h + 2 * Dim.pad.default,
                  function() self:seeAll(target) end)
    else
        table.insert(row, LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = label_h }, left })
    end
    return row
end

--- Opens the Library on the books a shelf was drawn from.
function HomeScreen:seeAll(target)
    Settings:set("library_group", "books")
    Settings:set("library_filter", target.filter)
    Settings:set("library_sort", target.sort)
    Settings:set("library_descending", target.descending)
    if self.plugin then self.plugin:openTab("library") end
end

function HomeScreen:stripBand(shelf, h, band_y)
    -- too few books to fill the row: wider cards that say more about each
    if #shelf.books < self.strip_cols then return self:cardsBand(shelf, h, band_y) end
    local w = self.screen_w
    local gap = W.GAP
    local cover_w = self.strip_cover_w
    local cols = self.strip_cols
    local cover_h = W.coverHeight(cover_w)
    local label_h = self:labelHeight()

    local content_h = label_h + Dim.pad.default + cover_h
    local top = band_y + math.floor((h - content_h) / 2)
    local header = self:shelfHeader(shelf, top)

    local row = HorizontalGroup:new{ align = "top" }
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

--- Text that wraps to at most `most` lines of `width`, cut with an ellipsis.
local function wrapped(str, face, size, colour, width, most)
    local box = TextBoxWidget:new{ text = str, face = Dim.face(face, size), fgcolor = colour, width = width }
    local cap = most * W.lineHeight(face, size)
    if box:getSize().h <= cap then return box end
    box:free()
    return TextBoxWidget:new{
        text = str, face = Dim.face(face, size), fgcolor = colour, width = width,
        height = cap, height_overflow_show_ellipsis = true,
    }
end

--- A shelf of a few books, each a cover with its title, author and where
--- you are in it, sharing the row's width.
function HomeScreen:cardsBand(shelf, h, band_y)
    local gap = W.GAP
    local n = #shelf.books
    local cover_w = self.strip_cover_w
    local cover_h = W.coverHeight(cover_w)
    local label_h = self:labelHeight()
    local area_w = self.screen_w - 2 * self.gutter
    local card_w = math.floor((area_w - (n - 1) * gap) / n)
    local text_w = card_w - cover_w - Dim.pad.large
    local top = band_y + math.floor((h - (label_h + Dim.pad.default + cover_h)) / 2)

    local row = HorizontalGroup:new{ align = "top" }
    for index, entry in ipairs(shelf.books) do
        if index > 1 then table.insert(row, hspan(gap)) end
        local col = VerticalGroup:new{ align = "left" }
        local room = cover_h
        local function put(widget)
            table.insert(col, widget)
            room = room - widget:getSize().h
        end
        local function lines(face, size, most)
            return math.min(most, math.floor(room / W.lineHeight(face, size)))
        end
        put(wrapped(entry.title, BOLD, 13.5, BLACK, text_w, math.max(1, lines(BOLD, 13.5, 3))))
        if entry.author ~= "" and lines(REGULAR, 11.5, 1) > 0 then
            put(text(entry.author, REGULAR, 11.5, MUTED, text_w))
        end
        if Books.started(entry) and room > Dim.px(16) then
            local pct = text(T("%1%", math.floor(entry.percent * 100 + 0.5)), REGULAR, 10.5, MUTED)
            put(VerticalSpan:new{ width = Dim.pad.default })
            put(HorizontalGroup:new{
                align = "center",
                W.progress(text_w - pct:getSize().w - Dim.pad.large, entry.percent),
                hspan(Dim.pad.large),
                pct,
            })
        else
            local fact = self:cardFact(entry)
            if fact and lines(REGULAR, 11, 1) > 0 then
                put(wrapped(fact, REGULAR, 11, BLACK, text_w, lines(REGULAR, 11, 2)))
            end
        end
        if n == 1 and entry.summary and lines(REGULAR, 11.5, 99) > 0 then
            put(VerticalSpan:new{ width = Dim.pad.default })
            put(wrapped(entry.summary, REGULAR, 11.5, MUTED, text_w, lines(REGULAR, 11.5, 99)))
        end
        table.insert(row, HorizontalGroup:new{
            align = "top",
            CoverTile.new(entry, cover_w, cover_h, { no_tag = true }),
            hspan(Dim.pad.large),
            col,
        })
        self:zone(self.gutter + (index - 1) * (card_w + gap), top + label_h + Dim.pad.default,
                  card_w, cover_h,
                  function() self:openBook(entry) end, function() self:holdBook(entry) end)
        if index < n then table.insert(row, hspan(card_w - cover_w - Dim.pad.large - col:getSize().w)) end
    end

    local inner = VerticalGroup:new{ align = "left" }
    table.insert(inner, self:shelfHeader(shelf, top))
    table.insert(inner, VerticalSpan:new{ width = Dim.pad.default })
    table.insert(inner, row)
    return band(self.screen_w, h, self.gutter, inner)
end

--- Where you are in a card's book that is not under way: which of its
--- series it is.
function HomeScreen:cardFact(entry)
    if entry.series and entry.series_index then
        local n = entry.series_index
        return T(_("Book %1 of %2"), n == math.floor(n) and string.format("%d", n) or n, entry.series)
    end
    return entry.status == "complete" and _("Finished") or nil
end

function HomeScreen:statusText()
    local server = Settings:get("server"):gsub("^https?://", "")
    if server == "" then server = _("no server set") end
    local busy = require("background").status()
    return busy and (server .. "  ·  " .. busy) or server
end

function HomeScreen:statusBand(h)
    local right = text(os.date("%H:%M"), REGULAR, 10.5, MUTED)
    local inner_w = self.screen_w - 2 * self.gutter
    -- never runs into the clock: cut with an ellipsis instead
    local left = text(self:statusText(), REGULAR, 10.5, MUTED,
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
        text(msg, REGULAR, 15, MUTED),
    })
end

--- The blurb, cut to whole lines that fit `room`, plus a "more" link when
--- it was cut. Either can be nil.
function HomeScreen:heroBlurb(entry, w, room)
    if not entry.summary then return nil end
    local face = Dim.face(REGULAR, 11.5)
    local line_h = W.lineHeight(REGULAR, 11.5)
    local blurb = TextBoxWidget:new{ text = entry.summary, face = face, width = w, fgcolor = MUTED }
    if blurb:getSize().h <= room then return blurb end
    blurb:free()
    local more = text(_("more"), BOLD, 11, BLACK)
    local lines = math.floor((room - more:getSize().h) / line_h)
    if lines < 2 then
        more:free()
        return nil
    end
    return TextBoxWidget:new{
        text = entry.summary, face = face, width = w, fgcolor = MUTED,
        height = lines * line_h, height_overflow_show_ellipsis = true,
    }, more
end

--- The continue card: cover on the left; on the right the title block at
--- the top and the progress block at the bottom, the blurb between them
--- getting whatever height is left. When even that runs out the least
--- important lines go.
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

    local overline = text(self.fresh and _("Up next") or _("Continue reading"), BOLD, 10.5, MUTED, meta_w)
    local title = wrapped(entry.title, BOLD, 20, BLACK, meta_w, 2)
    local author = entry.author ~= "" and text(entry.author, REGULAR, 13, MUTED, meta_w) or nil
    local details = self:heroDetails(entry, meta_w)

    local function heights(list)
        local sum = 0
        for _index, widget in ipairs(list) do sum = sum + widget:getSize().h end
        return sum
    end
    local used = overline:getSize().h + title:getSize().h + (author and author:getSize().h or 0)
                 + gap + heights(details)
    while used > inner_h and #details > 2 do
        used = used - table.remove(details):getSize().h
    end
    if used > inner_h and author then
        used = used - author:getSize().h
        author = nil
    end
    if used > inner_h then
        used = used - overline:getSize().h
        overline:free()
        overline = nil
    end

    local blurb, more
    if with_blurb then blurb, more = self:heroBlurb(entry, meta_w, inner_h - used - 2 * gap) end

    -- offsets are summed here: asking the group mid-build would freeze its layout
    local meta = VerticalGroup:new{ align = "left" }
    local meta_h = 0
    local function put(widget)
        table.insert(meta, widget)
        meta_h = meta_h + widget:getSize().h
    end
    if overline then put(overline) end
    put(title)
    if author then put(author) end
    local more_offset
    if blurb then
        put(VerticalSpan:new{ width = gap })
        put(blurb)
        if more then
            more_offset = meta_h
            put(more)
        end
    end
    -- the progress block sits on the cover's bottom edge
    put(VerticalSpan:new{ width = math.max(gap, inner_h - meta_h - heights(details)) })
    for _index, widget in ipairs(details) do put(widget) end

    local top = band_y + math.floor((h - math.max(cover_h, meta_h)) / 2)
    if more then
        local size = more:getSize()
        self:zone(meta_x, top + more_offset, size.w, size.h,
                  function() self:showBlurb(entry.title, entry.summary) end)
    end
    self:zone(0, band_y, self.screen_w, h, function() self:openBook(entry) end,
              function() self:holdBook(entry) end)

    return band(self.screen_w, h, self.gutter,
                HorizontalGroup:new{ align = "top", tile, hspan(self.gutter), meta })
end

--- "today 11:38", "yesterday", or "2 Oct".
local function when(time)
    if not time or time == 0 then return nil end
    local day = os.date("%Y%m%d", time)
    if day == os.date("%Y%m%d") then return T(_("today %1"), os.date("%H:%M", time)) end
    if day == os.date("%Y%m%d", os.time() - 86400) then return _("yesterday") end
    return os.date("%d %b", time)
end

--- The progress block under the title: percentage with the page on the
--- same line, the bar, and where it was last read. Widgets, the last ones
--- dropped first when the hero runs out of room.
function HomeScreen:heroDetails(entry, meta_w)
    if self.fresh then
        local fact = self:cardFact(entry)
        return { text(fact and (fact .. " · " .. _("not started")) or _("Not started"),
                      REGULAR, 11.5, MUTED, meta_w) }
    end
    local percent = entry.percent or 0
    local pct = text(T("%1%", math.floor(percent * 100 + 0.5)), BOLD, 15, BLACK)
    local line = HorizontalGroup:new{ align = "bottom", pct }
    if entry.pages then
        local page = text(T(_("page %1 of %2"), math.floor(percent * entry.pages + 0.5), entry.pages),
                          REGULAR, 11, MUTED)
        local room = meta_w - pct:getSize().w - page:getSize().w
        if room >= Dim.pad.large then
            table.insert(line, hspan(room))
            table.insert(line, page)
        else
            page:free()
        end
    end
    local out = { line, VerticalSpan:new{ width = Dim.pad.small }, W.progress(meta_w, percent, Dim.px(5)) }
    local where = entry.device or _("On this device")
    local at = when(entry.device and entry.synced_at or entry.last_read)
    table.insert(out, VerticalSpan:new{ width = Dim.pad.small })
    table.insert(out, text(at and (where .. " · " .. at) or where, REGULAR, 10.5, MUTED, meta_w))
    return out
end

-- behaviour ----------------------------------------------------------------

--- Back on the home screen leaves KOReader, the way it does from the file
--- browser this screen stands in for, honouring "Back to exit".
function HomeScreen:onClose()
    local function quit()
        UIManager:close(self)
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onClose() end
    end
    local back_to_exit = G_reader_settings:readSetting("back_to_exit", "prompt")
    if back_to_exit == "always" then
        quit()
    elseif back_to_exit == "prompt" then
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = _("Exit KOReader?"),
            ok_text = _("Exit"),
            ok_callback = quit,
        })
    end
    return true
end

function HomeScreen:showBlurb(title, summary)
    UIManager:show(require("ui/widget/textviewer"):new{
        title = title,
        text = summary,
    })
end

return HomeScreen
