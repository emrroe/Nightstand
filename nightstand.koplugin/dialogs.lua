--[[--
Nightstand's dialogs, in its own look rather than KOReader's: rounded white
cards in the same type and greys as the screens.

- `menu`: a card near the bottom, an optional book at its top, options with
  icons; tapping outside or Back closes it.
- `confirm`: a short question, an explanation, a quiet button and a filled
  one for the main choice.
- `note`: a small black note at the bottom that goes by itself.
- `working`: the same note, staying until the caller closes it.
--]]--

local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Dim = require("dim")
local W = require("widgets")
local _ = require("gettext")
local Screen = Device.screen

local Dialogs = {}

local function cardWidth()
    return math.floor(math.min(Screen:getWidth() * 0.92, Dim.px(400)))
end

local function card(content)
    return FrameContainer:new{
        background = W.WHITE, color = W.BLACK, bordersize = Size.border.thin,
        radius = Dim.px(10), padding = 0, margin = 0, content,
    }
end

--- A rounded button: filled for the main choice, outlined otherwise.
function Dialogs.button(text, filled, w)
    return FrameContainer:new{
        background = filled and W.BLACK or W.WHITE, color = W.BLACK,
        bordersize = Size.border.thin, radius = Dim.px(20), padding = 0, margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = Dim.px(38) },
            W.text(text, W.BOLD, 13, filled and W.WHITE or W.BLACK, w - Dim.px(16)),
        },
    }
end

-- A card over the screen. `targets` are { widget, callback } pairs found by
-- where they were painted; a tap elsewhere on the card does nothing, a tap
-- outside it closes.
local Card = InputContainer:extend{
    content = nil,
    at_bottom = false,
    targets = nil,
    dismissable = true,
    on_dismiss = nil,
}

function Card:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.frame = card(self.content)
    -- a bottom card keeps clear of the tab bar
    local lift = self.at_bottom and Dim.px(64) or 0
    local box = self.at_bottom and BottomContainer or CenterContainer
    self[1] = box:new{ dimen = Geom:new{ w = sw, h = sh - lift }, self.frame }
    self.key_events = { Close = { { Device.input.group.Back } } }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
    }
end

function Card:onTap(_arg, ges)
    local frame = self.frame.dimen
    if not frame or ges.pos:notIntersectWith(frame) then
        if self.dismissable then self:onClose() end
        return true
    end
    for _index, target in ipairs(self.targets or {}) do
        local d = target.widget.dimen
        if d and ges.pos:intersectWith(d) then
            UIManager:close(self)
            target.callback()
            return true
        end
    end
    return true
end

function Card:onClose()
    UIManager:close(self)
    if self.on_dismiss then self.on_dismiss() end
    return true
end

function Card:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function Card:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

--- Options in a card near the bottom. `opts.book` (an entry) puts its small
--- cover, title, author and `opts.subtitle` at the top; otherwise
--- `opts.title`. Each item: `{ icon, text, callback, separated, checked }`.
function Dialogs.menu(opts)
    local w = cardWidth()
    local pad = Dim.pad.large
    local group = VerticalGroup:new{ align = "left" }
    local targets = {}
    if opts.book then
        local CoverTile = require("covertile")
        local cover_w = Dim.px(38)
        local text_w = w - 2 * pad - cover_w - Dim.px(14)
        local words = VerticalGroup:new{ align = "left",
            W.text(opts.book.title, W.BOLD, 15, W.BLACK, text_w) }
        if opts.book.author and opts.book.author ~= "" then
            table.insert(words, W.text(opts.book.author, W.REGULAR, 11.5, W.MUTED, text_w))
        end
        if opts.subtitle then table.insert(words, W.text(opts.subtitle, W.REGULAR, 11, W.MUTED, text_w)) end
        table.insert(group, LeftContainer:new{
            dimen = Geom:new{ w = w, h = W.coverHeight(cover_w) + 2 * pad },
            HorizontalGroup:new{ align = "center", W.hspan(pad),
                CoverTile.new(opts.book, cover_w, W.coverHeight(cover_w), { no_tag = true }),
                W.hspan(Dim.px(14)), words },
        })
        table.insert(group, W.rule(w))
    elseif opts.title then
        table.insert(group, LeftContainer:new{
            dimen = Geom:new{ w = w, h = Dim.px(44) },
            HorizontalGroup:new{ W.hspan(pad), W.text(opts.title, W.BOLD, 14, W.BLACK, w - 2 * pad) },
        })
        table.insert(group, W.rule(w))
    end
    for index, item in ipairs(opts.items) do
        if item.separated and index > 1 then table.insert(group, W.rule(w)) end
        local label_w = w - 2 * pad - Dim.px(34) - (item.checked and Dim.px(24) or 0)
        local line = HorizontalGroup:new{ align = "center", W.hspan(pad) }
        table.insert(line, item.icon and W.icon(item.icon, 20) or W.hspan(Dim.px(20)))
        table.insert(line, W.hspan(Dim.px(14)))
        table.insert(line, W.text(item.text, item.checked and W.BOLD or W.REGULAR, 13, W.BLACK, label_w))
        if item.checked then
            table.insert(line, W.hspan(Dim.px(8)))
            table.insert(line, W.icon("check", 16))
        end
        -- a frame remembers where it was painted, so a tap can find the row
        local row = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
            LeftContainer:new{ dimen = Geom:new{ w = w, h = Dim.px(44) }, line } }
        table.insert(group, row)
        table.insert(targets, { widget = row, callback = item.callback })
    end
    table.insert(group, VerticalSpan:new{ width = Dim.pad.small })
    local dialog = Card:new{ content = group, at_bottom = true, targets = targets, items = opts.items }
    UIManager:show(dialog)
    return dialog
end

--- A question with a quiet Cancel and a filled main button. `opts`: title,
--- text, ok_text, ok_callback, cancel_text, cancel_callback.
function Dialogs.confirm(opts)
    local w = cardWidth()
    local pad = Dim.pad.large
    local inner = w - 2 * pad
    local group = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = pad } }
    local function line(widget) table.insert(group, HorizontalGroup:new{ W.hspan(pad), widget }) end
    if opts.title then
        line(TextBoxWidget:new{ text = opts.title, face = Dim.face(W.BOLD, 15.5), width = inner })
    end
    if opts.text then
        table.insert(group, VerticalSpan:new{ width = Dim.pad.default })
        line(TextBoxWidget:new{ text = opts.text, face = Dim.face(W.REGULAR, 12.5), fgcolor = W.MUTED, width = inner })
    end
    table.insert(group, VerticalSpan:new{ width = pad })
    local half = math.floor((inner - Dim.px(10)) / 2)
    local cancel = Dialogs.button(opts.cancel_text or _("Cancel"), false, half)
    local ok = Dialogs.button(opts.ok_text or _("OK"), true, half)
    table.insert(group, HorizontalGroup:new{ W.hspan(pad), cancel, W.hspan(Dim.px(10)), ok, W.hspan(pad) })
    table.insert(group, VerticalSpan:new{ width = pad })
    local cancelled = opts.cancel_callback or function() end
    local dialog = Card:new{
        content = group,
        targets = {
            { widget = cancel, callback = cancelled },
            { widget = ok, callback = opts.ok_callback or function() end },
        },
        dismissable = opts.dismissable ~= false,
        on_dismiss = cancelled,
        -- the two answers, by name, for code that answers on the reader's behalf
        ok_callback = opts.ok_callback,
        cancel_callback = cancelled,
    }
    UIManager:show(dialog)
    return dialog
end

-- A small black note at the bottom; a tap anywhere dismisses it.
local Note = InputContainer:extend{ text = nil, timeout = nil }

function Note:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local max_w = math.floor(sw * 0.86)
    local probe = W.text(self.text, W.REGULAR, 12.5, W.WHITE)
    local fits = probe:getSize().w <= max_w - 2 * Dim.pad.large
    probe:free()
    local body = fits and W.text(self.text, W.REGULAR, 12.5, W.WHITE)
        or TextBoxWidget:new{ text = self.text, face = Dim.face(W.REGULAR, 12.5), fgcolor = W.WHITE,
                              bgcolor = W.BLACK, width = max_w - 2 * Dim.pad.large }
    self.frame = FrameContainer:new{
        background = W.BLACK, bordersize = 0, radius = Dim.px(18), margin = 0,
        padding = Dim.pad.large, padding_top = Dim.pad.default, padding_bottom = Dim.pad.default,
        body,
    }
    self[1] = BottomContainer:new{ dimen = Geom:new{ w = sw, h = sh - Dim.px(70) }, self.frame }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } } }
    if self.timeout then
        self.close_task = function() UIManager:close(self) end
        UIManager:scheduleIn(self.timeout, self.close_task)
    end
end

function Note:onTap()
    UIManager:close(self)
    return true
end

function Note:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function Note:onCloseWidget()
    if self.close_task then UIManager:unschedule(self.close_task) end
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

--- A note that goes after a few seconds, longer for longer text.
function Dialogs.note(text, timeout)
    local note = Note:new{ text = text, timeout = timeout or math.max(3, math.min(8, #text / 20)) }
    UIManager:show(note)
    return note
end

--- A note that stays while slow work runs; close it with UIManager:close.
--- Drawn at once, since the work that follows keeps the screen from updating.
function Dialogs.working(text)
    local note = Note:new{ text = text }
    UIManager:show(note)
    UIManager:forceRePaint()
    return note
end

return Dialogs
