--[[--
Nightstand's home screen: layout A, "hero and grid".

Bands, top to bottom: status strip, continue card, library header, cover
grid, pager, tab bar. Heights come from fractions of the screen so the same
code fits a 1404x1872 tablet, an 824x1648 phone and a desktop window.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
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
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Books = require("books")
local CoverCache = require("covercache")
local Settings = require("settings")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GREY = Blitbuffer.COLOR_GRAY

-- Fractions of screen height, from the measured design.
local BAND = {
    status = 0.034,
    hero   = 0.286,
    head   = 0.045,
    pager  = 0.026,
    tabs   = 0.044,
}

local HomeScreen = InputContainer:extend{
    name = "nightstand_home",
    covers_fullscreen = true,
}

-- helpers ------------------------------------------------------------------

local function text(str, face_name, size, fg, max_width)
    return TextWidget:new{
        text = str or "",
        face = Font:getFace(face_name, size),
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
    end

    self.entries = Books:list(Settings:get("books_dir"))
    self.current, self.fresh = Books:current(self.entries)
    self.cols = Settings:get("grid_cols")
    self.rows = Settings:get("grid_rows")
    self.per_page = self.cols * self.rows
    self.pages = math.max(1, math.ceil(#self.entries / self.per_page))
    if self.page > self.pages then self.page = self.pages end

    self:build()
end

function HomeScreen:zone(x, y, w, h, callback)
    table.insert(self.tap_zones, { rect = Geom:new{ x = x, y = y, w = w, h = h }, cb = callback })
end

function HomeScreen:build()
    local w, h = self.screen_w, self.screen_h
    local heights = {}
    for key, fraction in pairs(BAND) do
        heights[key] = math.floor(h * fraction)
    end
    heights.grid = h - heights.status - heights.hero - heights.head
                     - heights.pager - heights.tabs

    local y = 0
    local stack = VerticalGroup:new{ align = "left" }

    local function add(widget, height)
        table.insert(stack, widget)
        y = y + height
    end

    add(self:statusBand(heights.status), heights.status)
    add(rule(w), Size.line.thin)
    y = y - Size.line.thin -- the rule is inside the status band's budget

    local hero_y = y
    add(self:heroBand(heights.hero, hero_y), heights.hero)
    add(rule(w), Size.line.thin)
    y = y - Size.line.thin

    add(self:headBand(heights.head), heights.head)
    add(self:gridBand(heights.grid, y + heights.head), heights.grid)
    y = y + 0 -- gridBand registered its own zones
    add(self:pagerBand(heights.pager, y), heights.pager)
    add(self:tabsBand(heights.tabs, y + heights.pager), heights.tabs)

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

function HomeScreen:statusBand(h)
    local server = Settings:get("server"):gsub("^https?://", "")
    if server == "" then server = _("no server set") end
    local left = text(server, "infont", 13, GREY)
    local right = text(os.date("%H:%M"), "infont", 13, GREY)
    local inner_w = self.screen_w - 2 * self.gutter
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{
            hspan(self.gutter),
            LeftContainer:new{ dimen = Geom:new{ w = inner_w - right:getSize().w, h = h }, left },
            right,
        },
    }
end

function HomeScreen:heroBand(h, band_y)
    local entry = self.current
    local pad = math.floor(h * 0.09)
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

    local cover_h = inner_h - math.floor(h * 0.16)
    local cover_w = math.floor(cover_h / 1.5)
    local tile = self:coverTile(entry, cover_w, cover_h, true)
    local meta_w = self.screen_w - 2 * self.gutter - cover_w - self.gutter

    local percent = entry.percent or 0
    local meta = VerticalGroup:new{ align = "left" }
    table.insert(meta, text(self.fresh and _("START READING") or _("CONTINUE"),
                            "infont", 11, GREY))
    table.insert(meta, VerticalSpan:new{ width = Size.padding.small })
    table.insert(meta, TextBoxWidget:new{
        text = entry.title, face = Font:getFace("tfont", 22),
        width = meta_w, alignment = "left",
    })
    if entry.author and entry.author ~= "" then
        table.insert(meta, text(entry.author, "cfont", 14, GREY, meta_w))
    end
    table.insert(meta, VerticalSpan:new{ width = Size.padding.default })
    if self.fresh then
        table.insert(meta, text(_("Not started"), "infont", 15, GREY))
    else
        table.insert(meta, text(string.format("%d%% read", math.floor(percent * 100 + 0.5)),
                                "infont", 15))
        table.insert(meta, ProgressWidget:new{
            width = meta_w, height = math.floor(h * 0.035),
            percentage = percent, bordersize = 0,
            fillcolor = BLACK, bgcolor = GREY,
        })
        if entry.pages then
            table.insert(meta, text(T(_("page %1 of %2"),
                                      math.floor(percent * entry.pages + 0.5), entry.pages),
                                    "infont", 12, GREY, meta_w))
        end
    end

    self:zone(0, band_y, self.screen_w, h, function() self:openBook(entry) end)

    return band(self.screen_w, h, self.gutter,
                HorizontalGroup:new{ align = "top", tile, hspan(self.gutter), meta })
end

function HomeScreen:headBand(h)
    local label = T(_("LIBRARY  ·  %1 books"), #self.entries)
    return band(self.screen_w, h, self.gutter, text(label, "infont", 12))
end

function HomeScreen:gridBand(h, band_y)
    local w = self.screen_w
    local gap = math.floor(w * 0.018)
    local area_w = w - 2 * self.gutter
    local caption_h = math.floor(h * 0.12)
    local cell_h = math.floor((h - (self.rows - 1) * gap) / self.rows)
    local cover_h = cell_h - caption_h
    local cover_w = math.min(math.floor((area_w - (self.cols - 1) * gap) / self.cols),
                             math.floor(cover_h / 1.5))
    cover_h = math.floor(cover_w * 1.5)

    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1

    for row = 1, self.rows do
        local line = HorizontalGroup:new{ align = "top" }
        for col = 1, self.cols do
            local idx = first + (row - 1) * self.cols + (col - 1)
            local entry = self.entries[idx]
            if col > 1 then table.insert(line, hspan(gap)) end
            if entry then
                local cell = VerticalGroup:new{ align = "left" }
                table.insert(cell, self:coverTile(entry, cover_w, cover_h))
                table.insert(cell, text(entry.title, "cfont", 12, BLACK, cover_w))
                table.insert(cell, text(Books:progressTag(entry), "infont", 10, GREY, cover_w))
                table.insert(line, cell)

                local x = self.gutter + (col - 1) * (cover_w + gap)
                local cy = band_y + (row - 1) * (cell_h + gap)
                self:zone(x, cy, cover_w, cover_h, function() self:openBook(entry) end)
            else
                table.insert(line, hspan(cover_w))
            end
        end
        table.insert(grid, line)
        if row < self.rows then
            table.insert(grid, VerticalSpan:new{ width = gap })
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
    local labels = { _("HOME"), _("LIBRARY"), _("SERIES"), _("AUTHORS"), _("SETTINGS") }
    local tab_w = math.floor(self.screen_w / #labels)
    local row = HorizontalGroup:new{ align = "top" }
    table.insert(row, rule(self.screen_w))

    local strip = HorizontalGroup:new{ align = "top" }
    for i, label in ipairs(labels) do
        local active = i == 1
        local cell = VerticalGroup:new{ align = "center" }
        if active then
            table.insert(cell, LineWidget:new{
                background = BLACK,
                dimen = Geom:new{ w = tab_w, h = math.floor(h * 0.08) },
            })
        end
        table.insert(cell, CenterContainer:new{
            dimen = Geom:new{ w = tab_w, h = h - math.floor(h * 0.08) },
            text(label, "infont", 11, active and BLACK or GREY),
        })
        table.insert(strip, cell)
        self:zone((i - 1) * tab_w, band_y, tab_w, h, function() self:onTab(i) end)
    end

    return VerticalGroup:new{ align = "left", rule(self.screen_w), strip }
end

-- a cover, with its two corner marks ---------------------------------------

function HomeScreen:coverTile(entry, w, h, no_tag)
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
    if not no_tag then
        local tag = Books:progressTag(entry)
        local solid = tag ~= "New" and tag ~= "Finished"
        local badge = FrameContainer:new{
            background = solid and BLACK or WHITE,
            color = BLACK,
            bordersize = solid and 0 or Size.border.thin,
            padding = Size.padding.tiny,
            margin = 0,
            radius = 0,
            text(tag, "infont", 10, solid and WHITE or BLACK),
        }
        badge.overlap_offset = { w - badge:getSize().w - pad, pad }
        table.insert(group, badge)
    end

    if not entry.on_device then
        local disc = FrameContainer:new{
            background = BLACK, bordersize = 0, margin = 0,
            padding = Size.padding.tiny, radius = math.floor(w * 0.07),
            text("\u{2193}", "infont", 12, WHITE),
        }
        local size = disc:getSize()
        disc.overlap_offset = { w - size.w - pad, h - size.h - pad }
        table.insert(group, disc)
    end

    return group
end

function HomeScreen:placeholderCover(entry, w, h)
    local border = Size.border.thin
    local pad = Size.padding.small
    local inner_w = w - 2 * border - 2 * pad
    return FrameContainer:new{
        background = WHITE, color = GREY, bordersize = border,
        padding = pad, margin = 0, radius = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = h - 2 * border - 2 * pad },
            TextBoxWidget:new{
                text = entry.title, face = Font:getFace("tfont", 13),
                width = inner_w, alignment = "center",
            },
        },
    }
end

-- behaviour ----------------------------------------------------------------

function HomeScreen:openBook(entry)
    UIManager:close(self)
    require("apps/reader/readerui"):showReader(entry.file)
end

function HomeScreen:turnPage(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    self:refresh()
end

function HomeScreen:onTab(index)
    if index == 1 then return end
    UIManager:show(require("ui/widget/infomessage"):new{
        text = _("That tab is next on the list."),
        timeout = 2,
    })
end

function HomeScreen:refresh()
    self.tap_zones = {}
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

return HomeScreen
