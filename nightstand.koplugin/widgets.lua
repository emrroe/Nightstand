--[[--
The small building blocks every Nightstand screen is made of, and the
measurements they share.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Dim = require("dim")

local W = {
    BLACK = Blitbuffer.COLOR_BLACK,
    WHITE = Blitbuffer.COLOR_WHITE,
    GREY = Blitbuffer.COLOR_GRAY,
    -- secondary text, and the hairlines and empty tracks behind it
    MUTED = Blitbuffer.Color8(0x5c),
    FAINT = Blitbuffer.Color8(0xdc),
    -- one family throughout, both weights shipped with KOReader
    REGULAR = "NotoSans-Regular.ttf",
    BOLD = "NotoSans-Bold.ttf",
    COVER_ASPECT = 1.5,
    GAP = Dim.px(8),
    STATUS_H = Dim.px(27),
}

--- Side margin for a screen of width `w`.
function W.gutter(w)
    return math.floor(w * 0.023)
end

function W.coverHeight(cover_w)
    return math.floor(cover_w * W.COVER_ASPECT)
end

function W.text(str, face, size, colour, max_width)
    return TextWidget:new{
        text = str or "",
        face = Dim.face(face, size),
        fgcolor = colour or W.BLACK,
        max_width = max_width,
    }
end

--- Height of one line of text in a face, measured rather than guessed.
function W.lineHeight(face, size)
    local probe = W.text("Ag", face, size)
    local h = probe:getSize().h
    probe:free()
    return h
end

function W.hspan(w)
    return HorizontalSpan:new{ width = w }
end

function W.rule(w, colour)
    return LineWidget:new{ background = colour or W.FAINT, dimen = Geom:new{ w = w, h = Size.line.thin } }
end

--- A progress bar: a rounded black fill on a light track.
function W.progress(w, fraction, h)
    h = h or Dim.px(4)
    local radius = math.floor(h / 2)
    local fill_w = math.max(fraction > 0 and h or 0, math.floor(w * math.min(1, fraction)))
    local group = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, allow_mirroring = false }
    table.insert(group, FrameContainer:new{
        background = W.FAINT, bordersize = 0, padding = 0, margin = 0, radius = radius,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, VerticalSpan:new{ width = 0 } },
    })
    if fill_w > 0 then
        table.insert(group, FrameContainer:new{
            background = W.BLACK, bordersize = 0, padding = 0, margin = 0, radius = radius,
            CenterContainer:new{ dimen = Geom:new{ w = fill_w, h = h }, VerticalSpan:new{ width = 0 } },
        })
    end
    return group
end

local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")

--- One of the bundled line icons, `size` units square (or `px` pixels).
function W.icon(name, size, px)
    local ImageWidget = require("ui/widget/imagewidget")
    px = px or Dim.px(size)
    return ImageWidget:new{
        file = PLUGIN_DIR .. "/resources/" .. name .. ".svg",
        width = px, height = px, alpha = true,
    }
end

--- A tab in an underlined tab row: bold with a bar under it when active.
--- Returns the widget; `h` is the row height, the bar sits on its bottom edge.
function W.tab(label, active, h)
    local bar = Dim.px(3)
    local text = W.text(label, active and W.BOLD or W.REGULAR, 12.5, active and W.BLACK or W.MUTED)
    local w = text:getSize().w
    return VerticalGroup:new{
        align = "left",
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h - bar }, text },
        LineWidget:new{ background = active and W.BLACK or W.WHITE, dimen = Geom:new{ w = w, h = bar } },
    }
end

--- A text control that opens a menu: its value and an icon after it
--- (a chevron, or the sort direction).
function W.dropdown(value, icon)
    return HorizontalGroup:new{
        align = "center",
        W.text(value, W.BOLD, 12, W.BLACK),
        W.hspan(Dim.pad.small),
        W.icon(icon or "chevron-down", 12),
    }
end

--- A band of exactly `h` pixels, contents left-aligned after a side gutter.
function W.band(w, h, gutter, inner)
    return LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{ W.hspan(gutter), inner },
    }
end

local function box(w, h)
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, VerticalSpan:new{ width = 0 } }
end

--- Filled with the knob right for on, outlined with it left for off: two cues,
--- neither of them colour.
function W.toggle(on)
    local h = Dim.px(19)
    local w = math.floor(h * 1.9)
    local knob = h - Dim.px(7)
    local inset = math.floor((h - knob) / 2)
    local track = FrameContainer:new{
        background = on and W.BLACK or W.WHITE,
        color = W.BLACK,
        bordersize = Size.border.thin,
        padding = 0, margin = 0,
        radius = math.floor(h / 2),
        box(w, h),
    }
    local dot = FrameContainer:new{
        background = on and W.WHITE or W.BLACK,
        bordersize = 0, padding = 0, margin = 0,
        radius = math.floor(knob / 2),
        box(knob, knob),
    }
    local size = track:getSize()
    dot.overlap_offset = {
        on and (size.w - knob - inset - Size.border.thin) or (inset + Size.border.thin),
        inset + Size.border.thin,
    }
    local group = OverlapGroup:new{ dimen = Geom:new{ w = size.w, h = size.h }, allow_mirroring = false }
    table.insert(group, track)
    table.insert(group, dot)
    return group
end

--- A vertical stack that tracks the y where the next band starts, which is
--- what tap zones are registered against.
function W.stack()
    local stack = { y = 0, group = VerticalGroup:new{ align = "left" } }
    function stack:add(widget, height)
        table.insert(self.group, widget)
        self.y = self.y + height
    end
    function stack:space(height)
        self:add(VerticalSpan:new{ width = height }, height)
    end
    return stack
end

--- The white, borderless frame a full-screen view paints into.
function W.fullscreen(w, h, content)
    return FrameContainer:new{
        width = w, height = h, background = W.WHITE,
        bordersize = 0, padding = 0, margin = 0,
        content,
    }
end

return W
