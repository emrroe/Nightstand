--[[--
A book's details over the current screen: its cover with the title, author
and a few facts beside it, the description flowing on beside the cover and
then full width below it, and rows of buttons at the bottom. Used by Home,
the Library and Discover.

A description too long for one page is split into pages, turned by swiping
or by tapping the right or left half of the text, like a book. Closes with
Back, a tap outside it, or whichever button closes it.
--]]--

local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CoverTile = require("covertile")
local Dim = require("dim")
local W = require("widgets")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local TEXT_SIZE = 12

local BookSheet = InputContainer:extend{
    entry = nil,        -- what the cover is drawn from
    title = nil,
    author = nil,
    facts = nil,        -- short lines under the author
    description = nil,
    buttons = nil,      -- rows of { text, callback }; a Close row is added
}

local function lines(text, width)
    return TextBoxWidget:new{ text = text, face = Dim.face(W.REGULAR, TEXT_SIZE), fgcolor = W.BLACK,
                              width = width }
end

--- `text` cut after its first `n` lines at `width`: the part that fits,
--- and the rest (nil when it all fits).
function BookSheet.split(text, width, n)
    if not text or n < 1 then return nil, text end
    local probe = lines(text, width)
    local list = probe.vertical_string_list or {}
    local line, next_line = list[n], list[n + 1]
    probe:free()
    if not line or not next_line then return text, nil end
    local chars = require("util").splitToChars(text)
    local cut = line.next_start_offset or next_line.offset
    if not cut or cut > #chars then return text, nil end
    local first = table.concat(chars, "", 1, cut - 1):gsub("%s+$", "")
    local rest = table.concat(chars, "", cut):gsub("^%s+", "")
    return first, rest ~= "" and rest or nil
end

function BookSheet:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.pad = Dim.pad.large
    local w = math.floor(math.min(sw * 0.94, Dim.px(560)))
    self.inner_w = w - 2 * self.pad - 2 * Size.border.window
    self.cover_w = math.floor(self.inner_w * 0.3)
    self.text_w = self.inner_w - self.cover_w - self.pad
    -- the description box's own line height, line spacing included
    local probe = lines("Ag", self.inner_w)
    self.line_h = probe.line_height_px or probe:getSize().h
    probe:free()
    self:plan(sh)
    self.page = 1
    self:render()

    self.key_events = { Close = { { Device.input.group.Back } } }
    local all = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
end

--- The title column beside the cover, and its height (summed here: a
--- group asked its size mid-build keeps it).
function BookSheet:head()
    local head = VerticalGroup:new{ align = "left" }
    local h = 0
    local function put(widget)
        table.insert(head, widget)
        h = h + widget:getSize().h
    end
    local function wrapped(str, face, size, colour, most)
        put(TextBoxWidget:new{
            text = str, face = Dim.face(face, size), fgcolor = colour, width = self.text_w,
            height = most * W.lineHeight(face, size), height_overflow_show_ellipsis = true,
            height_adjust = true,
        })
    end
    wrapped(self.title or "", W.BOLD, 17, W.BLACK, 3)
    if self.author and self.author ~= "" then wrapped(self.author, W.REGULAR, 12.5, W.MUTED, 2) end
    put(VerticalSpan:new{ width = Dim.pad.default })
    for _index, fact in ipairs(self.facts or {}) do wrapped(fact, W.REGULAR, 11.5, W.BLACK, 2) end
    return head, h
end

function BookSheet:buttonTable()
    local rows = {}
    for _index, row in ipairs(self.buttons or {}) do
        local out = {}
        for _index2, button in ipairs(row) do
            local callback = button.callback
            table.insert(out, { text = button.text, callback = function()
                UIManager:close(self)
                callback()
            end })
        end
        table.insert(rows, out)
    end
    table.insert(rows, { { text = _("Close"), callback = function() self:onClose() end } })
    return ButtonTable:new{ width = self.inner_w, buttons = rows, zero_sep = true, show_parent = self }
end

--- Cut the description into pages once: lines beside the cover (as many as
--- fill it to the cover's foot, the cover sized to match), then full-width
--- lines under it, then further pages of full-width text.
function BookSheet:plan(sh)
    local head, head_h = self:head()
    head:free()
    local probe = self:buttonTable()
    local buttons_h = probe:getSize().h
    probe:free()
    local natural = W.coverHeight(self.cover_w)
    local gap = Dim.pad.default
    local text = self.description ~= "" and self.description or nil

    -- lines beside the cover, and the cover's height to sit flush with them;
    -- within what the cover can be cropped to without looking squashed
    local beside_n = 0
    if text then
        beside_n = math.max(0, math.floor((natural - head_h - gap) / self.line_h + 0.5))
        local ratio = function(n) return (head_h + gap + n * self.line_h) / self.cover_w end
        while beside_n > 0 and ratio(beside_n) > 1.7 do beside_n = beside_n - 1 end
        while ratio(beside_n + 1) <= 1.3 do beside_n = beside_n + 1 end
    end
    self.cover_h = beside_n > 0 and (head_h + gap + beside_n * self.line_h) or natural
    local top_h = math.max(self.cover_h, head_h)

    local beside, rest = BookSheet.split(text, self.text_w, beside_n)
    self.pages = { { beside = beside } }
    if not rest then return end
    -- room for text: most of the screen, less the frame and the buttons
    local room = math.floor(sh * 0.88) - 2 * self.pad - 2 * Size.border.window - buttons_h - self.pad
    local first, after = BookSheet.split(rest, self.inner_w, math.floor((room - top_h) / self.line_h))
    self.pages[1].below = first
    if not after then return end
    -- more pages: each as tall as the first, which also makes room for the page line
    local indicator_h = W.lineHeight(W.REGULAR, 11) + Dim.pad.default
    local below_n = math.floor((room - indicator_h - top_h) / self.line_h)
    first, after = BookSheet.split(rest, self.inner_w, below_n)
    self.pages[1].below = first
    self.page_h = top_h + below_n * self.line_h
    local full_n = math.floor(self.page_h / self.line_h)
    while after do
        first, after = BookSheet.split(after, self.inner_w, full_n)
        table.insert(self.pages, { text = first })
    end
end

function BookSheet:render()
    if self[1] then self[1]:free() end
    local page = self.pages[self.page]
    local column = VerticalGroup:new{ align = "left" }
    local text_h
    if self.page == 1 then
        local head = self:head()
        if page.beside then
            table.insert(head, VerticalSpan:new{ width = Dim.pad.default })
            table.insert(head, lines(page.beside, self.text_w))
        end
        table.insert(column, HorizontalGroup:new{
            align = "top",
            CoverTile.new(self.entry, self.cover_w, self.cover_h, { no_tag = true }),
            W.hspan(self.pad),
            head,
        })
        text_h = self.cover_h
        if page.below then
            local below = lines(page.below, self.inner_w)
            table.insert(column, below)
            text_h = text_h + below:getSize().h
        end
    else
        local text = lines(page.text, self.inner_w)
        table.insert(column, text)
        text_h = text:getSize().h
    end
    -- every page as tall as the first, so turning does not make it jump
    if self.page_h and text_h < self.page_h then
        table.insert(column, VerticalSpan:new{ width = self.page_h - text_h })
    end
    if #self.pages > 1 then table.insert(column, self:indicator()) end
    table.insert(column, VerticalSpan:new{ width = self.pad })
    self.button_table = self:buttonTable()
    table.insert(column, self.button_table)

    self.frame = FrameContainer:new{
        background = W.WHITE, bordersize = Size.border.window, radius = Size.radius.window,
        padding = self.pad, margin = 0,
        column,
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }, self.frame }
end

--- "‹  2 of 3  ›" under the text, the arrows greyed at either end.
function BookSheet:indicator()
    local first, last = self.page == 1, self.page == #self.pages
    return CenterContainer:new{
        dimen = Geom:new{ w = self.inner_w, h = W.lineHeight(W.REGULAR, 11) + Dim.pad.default },
        HorizontalGroup:new{
            align = "center",
            W.icon(first and "chevron-left-off" or "chevron-left", 13),
            W.hspan(Dim.px(14)),
            W.text(T(_("%1 of %2"), self.page, #self.pages), W.REGULAR, 11, W.MUTED),
            W.hspan(Dim.px(14)),
            W.icon(last and "chevron-right-off" or "chevron-right", 13),
        },
    }
end

function BookSheet:turn(delta)
    local page = self.page + delta
    if page < 1 or page > #self.pages then return end
    self.page = page
    self:render()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

--- A tap outside closes; a tap on the text turns the page by which half it
--- lands on. Taps on the buttons never get here.
function BookSheet:onTap(_arg, ges)
    local frame = self.frame.dimen
    if not frame or ges.pos:notIntersectWith(frame) then return self:onClose() end
    local buttons = self.button_table and self.button_table.dimen
    if #self.pages > 1 and (not buttons or ges.pos.y < buttons.y) then
        self:turn(ges.pos.x >= frame.x + frame.w / 2 and 1 or -1)
    end
    return true
end

function BookSheet:onSwipe(_arg, ges)
    if ges.direction == "west" then self:turn(1)
    elseif ges.direction == "east" then self:turn(-1) end
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
