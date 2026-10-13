--[[--
A book's details over the current screen: its cover beside the title,
author and a few facts, the description under them (scrolling when long),
and rows of buttons at the bottom. Used by the Library and Discover.

Closes with Back, a tap outside it, or whichever button closes it.
--]]--

local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CoverTile = require("covertile")
local Dim = require("dim")
local W = require("widgets")
local _ = require("gettext")
local Screen = Device.screen

local BookSheet = InputContainer:extend{
    entry = nil,        -- what the cover is drawn from
    title = nil,
    author = nil,
    facts = nil,        -- short lines under the author
    description = nil,
    buttons = nil,      -- rows of { text, callback }; a Close row is added
}

function BookSheet:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local w = math.floor(math.min(sw * 0.94, Dim.px(560)))
    local pad = Dim.pad.large
    local inner_w = w - 2 * pad - 2 * Size.border.window
    local cover_w = math.floor(inner_w * 0.3)
    local text_w = inner_w - cover_w - pad

    local head = VerticalGroup:new{ align = "left" }
    local function wrapped(str, face, size, colour, lines)
        return TextBoxWidget:new{
            text = str, face = Dim.face(face, size), fgcolor = colour, width = text_w,
            height = lines * W.lineHeight(face, size), height_overflow_show_ellipsis = true,
            height_adjust = true,
        }
    end
    table.insert(head, wrapped(self.title or "", W.BOLD, 17, W.BLACK, 3))
    if self.author and self.author ~= "" then
        table.insert(head, wrapped(self.author, W.REGULAR, 12.5, W.MUTED, 2))
    end
    table.insert(head, VerticalSpan:new{ width = Dim.pad.default })
    for _index, fact in ipairs(self.facts or {}) do
        table.insert(head, wrapped(fact, W.REGULAR, 11.5, W.BLACK, 2))
    end

    local close = function() self:onClose() end
    local rows = {}
    for _index, row in ipairs(self.buttons or {}) do
        local out = {}
        for _index2, button in ipairs(row) do
            local callback = button.callback
            table.insert(out, { text = button.text, callback = function()
                if not button.keep_open then UIManager:close(self) end
                callback()
            end })
        end
        table.insert(rows, out)
    end
    table.insert(rows, { { text = _("Close"), callback = close } })
    local buttons = ButtonTable:new{ width = inner_w, buttons = rows, zero_sep = true, show_parent = self }

    local cover_h = W.coverHeight(cover_w)
    local top_h = math.max(cover_h, head:getSize().h)
    local room = math.floor(sh * 0.86) - 2 * pad - top_h - pad - buttons:getSize().h
    local line_h = W.lineHeight(W.REGULAR, 12)
    local body
    if self.description and self.description ~= "" and room >= 3 * line_h then
        body = ScrollTextWidget:new{
            text = self.description, face = Dim.face(W.REGULAR, 12), fgcolor = W.BLACK,
            width = inner_w, height = math.min(room, self:descriptionHeight(inner_w, line_h)),
            dialog = self,
        }
    end

    local column = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "top",
            CoverTile.new(self.entry, cover_w, cover_h, { no_tag = true }),
            W.hspan(pad),
            head,
        },
        VerticalSpan:new{ width = pad },
    }
    if body then
        table.insert(column, body)
        table.insert(column, VerticalSpan:new{ width = pad })
    end
    table.insert(column, buttons)

    self.frame = FrameContainer:new{
        background = W.WHITE, bordersize = Size.border.window, radius = Size.radius.window,
        padding = pad, margin = 0,
        column,
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, self.frame }

    self.key_events = { Close = { { Device.input.group.Back } } }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
    }
end

--- Height the whole description would need, so a short one leaves no gap.
function BookSheet:descriptionHeight(width, line_h)
    local probe = TextBoxWidget:new{ text = self.description, face = Dim.face(W.REGULAR, 12), width = width }
    local h = probe:getSize().h
    probe:free()
    return math.max(line_h, h)
end

function BookSheet:onTapOutside(_arg, ges)
    if self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

function BookSheet:onClose()
    UIManager:close(self)
    return true
end

function BookSheet:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function BookSheet:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

return BookSheet
