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
    -- Book titles get a serif; the chrome stays sans and the data stays mono.
    SERIF = "NotoSerif-Bold.ttf",
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

function W.rule(w)
    return LineWidget:new{ background = W.GREY, dimen = Geom:new{ w = w, h = Size.line.thin } }
end

--- A band of exactly `h` pixels, contents left-aligned after a side gutter.
function W.band(w, h, gutter, inner)
    return LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{ W.hspan(gutter), inner },
    }
end

--- A filter chip: inverted when active, so the state never depends on colour.
function W.chip(label, active)
    return FrameContainer:new{
        background = active and W.BLACK or W.WHITE,
        color = W.BLACK,
        bordersize = Size.border.thin,
        padding = Dim.pad.default,
        padding_top = Dim.pad.small, padding_bottom = Dim.pad.small,
        margin = 0,
        radius = Dim.px(4),
        W.text(label, "infont", 12, active and W.WHITE or W.BLACK),
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
