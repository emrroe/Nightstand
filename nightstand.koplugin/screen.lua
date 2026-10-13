--[[--
Base for Nightstand's full-screen views.

A screen is built from bands stacked top to bottom; while building, each band
registers the tap zones it draws, so taps are resolved against geometry the
screen computed itself rather than against widget hit-testing. Subclasses
supply `load` (gather data) and `build` (lay out and register zones), and set
`tab_id` to light up their tab.
--]]--

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Dim = require("dim")
local Settings = require("settings")
local TabBar = require("tabbar")
local W = require("widgets")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local NightstandScreen = InputContainer:extend{
    covers_fullscreen = true,
    tab_id = nil,
    pageable = false,  -- swipes turn pages
}

-- every Nightstand screen currently open, so they can all close together
NightstandScreen.open_screens = {}

--- Close every Nightstand screen, e.g. before the reader takes over: one
--- left underneath would sit between the reader and the next file browser.
function NightstandScreen.closeAll()
    local screens = {}
    for screen in pairs(NightstandScreen.open_screens) do table.insert(screens, screen) end
    for _index, screen in ipairs(screens) do UIManager:close(screen) end
end

function NightstandScreen:init()
    NightstandScreen.open_screens[self] = true
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.gutter = W.gutter(self.screen_w)
    self.tap_zones = {}

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = full } }
        self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = full } }
        if self.pageable then
            self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = full } }
        end
    end

    self:load()
    self:build()
end

function NightstandScreen:load() end

function NightstandScreen:build() end

--- Install the built content as the screen's single, full-size child.
function NightstandScreen:setContent(content)
    self[1] = W.fullscreen(self.screen_w, self.screen_h, content)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
end

--- Rebuild in place, releasing the previous widget tree first.
function NightstandScreen:refresh()
    if self[1] then self[1]:free() end
    self.tap_zones = {}
    self:build()
    UIManager:setDirty(self, "ui")
end

--- Gather the data again (the catalogue changed underneath), then rebuild.
function NightstandScreen:reload()
    self:load()
    self:refresh()
end

function NightstandScreen:zone(x, y, w, h, on_tap, on_hold)
    -- generous margins around a target may reach past the screen edge
    local x0, y0 = math.max(0, math.floor(x)), math.max(0, math.floor(y))
    local x1 = math.min(self.screen_w, math.floor(x + w))
    local y1 = math.min(self.screen_h, math.floor(y + h))
    table.insert(self.tap_zones, { rect = Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 },
                                   tap = on_tap, hold = on_hold })
end

function NightstandScreen:onTap(_arg, ges)
    for _index, zone in ipairs(self.tap_zones) do
        if zone.tap and zone.rect:contains(ges.pos) then
            zone.tap()
            return true
        end
    end
    return true
end

function NightstandScreen:onHold(_arg, ges)
    for _index, zone in ipairs(self.tap_zones) do
        if zone.hold and zone.rect:contains(ges.pos) then
            zone.hold()
            return true
        end
    end
    return true
end

function NightstandScreen:onSwipe(_arg, ges)
    if not self.turnPage then return false end
    if ges.direction == "west" then
        self:turnPage(1)
    elseif ges.direction == "east" then
        self:turnPage(-1)
    end
    return true
end

function NightstandScreen:openBook(entry)
    require("bookactions").open(self, entry)
end

--- Long-press on a cover: earlier reading positions to go back to.
function NightstandScreen:holdBook(entry)
    require("bookactions").hold(self, entry)
end

--- A row of underlined tabs over a hairline; `tabs` are `{ label, active,
--- on_tap }`. Tabs that do not fit are left off the end.
function NightstandScreen:tabRow(h, band_y, tabs)
    local row = HorizontalGroup:new{ align = "bottom" }
    local x = self.gutter
    local space = Dim.px(18)
    local limit = self.screen_w - self.gutter
    for index, tab in ipairs(tabs) do
        local widget = W.tab(tab.label, tab.active, h - Size.line.thin)
        local tab_w = widget:getSize().w
        if x + tab_w > limit then
            widget:free()
            break
        end
        if index > 1 then table.insert(row, W.hspan(space)) end
        table.insert(row, widget)
        -- the gap either side belongs to the nearer tab
        self:zone(x - space / 2, band_y, tab_w + space, h, tab.on_tap)
        x = x + tab_w + space
    end
    return VerticalGroup:new{
        align = "left",
        LeftContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = h - Size.line.thin },
            HorizontalGroup:new{ align = "bottom", W.hspan(self.gutter), row },
        },
        W.rule(self.screen_w),
    }
end

--- Dropdowns side by side: `left` from the gutter, `right` against the far
--- edge. Each is `{ widget, on_tap }`.
function NightstandScreen:controlRow(h, band_y, left, right)
    local space = Dim.px(18)
    local row = HorizontalGroup:new{ align = "center", W.hspan(self.gutter) }
    local x = self.gutter
    for index, c in ipairs(left) do
        if index > 1 then
            table.insert(row, W.hspan(space))
            x = x + space
        end
        local cw = c.widget:getSize().w
        table.insert(row, c.widget)
        self:zone(x - space / 2, band_y, cw + space, h, c.on_tap)
        x = x + cw
    end
    if right then
        local rw = right.widget:getSize().w
        local gap = self.screen_w - self.gutter - rw - x
        table.insert(row, W.hspan(math.max(space, gap)))
        table.insert(row, right.widget)
        self:zone(self.screen_w - self.gutter - rw - space / 2, band_y, rw + space / 2 + self.gutter, h, right.on_tap)
    end
    return LeftContainer:new{ dimen = Geom:new{ w = self.screen_w, h = h }, row }
end

--- "‹  2 of 5  ›" with the arrows as the outer thirds; `middle` adds text
--- after the count and makes the middle third a button.
function NightstandScreen:pagerBand(h, band_y, middle, on_middle)
    local third = math.floor(self.screen_w / 3)
    local row = HorizontalGroup:new{ align = "center" }
    local first, last = self.page <= 1, self.page >= self.pages
    if self.pages > 1 then
        table.insert(row, W.icon(first and "chevron-left-off" or "chevron-left", 16))
        table.insert(row, W.hspan(Dim.px(22)))
        table.insert(row, W.text(T(_("%1 of %2"), self.page, self.pages), W.REGULAR, 11.5, W.MUTED))
        self:zone(0, band_y, third, h, function() self:turnPage(-1) end)
        self:zone(2 * third, band_y, third, h, function() self:turnPage(1) end)
    end
    if middle then
        table.insert(row, W.text((self.pages > 1 and "  ·  " or "") .. middle, W.REGULAR, 11.5, W.MUTED))
        if on_middle then self:zone(third, band_y, third, h, on_middle) end
    end
    if self.pages > 1 then
        table.insert(row, W.hspan(Dim.px(22)))
        table.insert(row, W.icon(last and "chevron-right-off" or "chevron-right", 16))
    end
    return CenterContainer:new{ dimen = Geom:new{ w = self.screen_w, h = h }, row }
end

--- An empty or offline state: an icon, a sentence or two, and a button
--- when there is something useful to do about it. `h` is the height it
--- centres in; `band_y` where that starts on screen.
function NightstandScreen:emptyState(w, h, band_y, icon, message, action_text, action)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalSpan = require("ui/widget/verticalspan")
    local text_w = math.min(w - 4 * self.gutter, Dim.px(320))
    local column = VerticalGroup:new{ align = "center" }
    local column_h = 0
    local function put(widget)
        table.insert(column, widget)
        column_h = column_h + widget:getSize().h
    end
    if icon and h >= Dim.px(150) then
        put(W.icon(icon, 28))
        put(VerticalSpan:new{ width = Dim.pad.large })
    end
    put(TextBoxWidget:new{ text = message, face = Dim.face(W.REGULAR, 13), fgcolor = W.MUTED,
                           width = text_w, alignment = "center" })
    local button
    if action_text and action then
        put(VerticalSpan:new{ width = Dim.pad.large })
        button = require("dialogs").button(action_text, false, math.min(text_w, Dim.px(200)))
        put(button)
    end
    if button then
        -- the button's place: centred, at the foot of the centred column
        local bw, bh = button:getSize().w, button:getSize().h
        local top = band_y + math.floor((h - column_h) / 2)
        self:zone(math.floor((w - bw) / 2), top + column_h - bh, bw, bh, action)
    end
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, column }
end

--- A menu of options with the current one ticked (`mark` is added after it,
--- e.g. the sort direction).
function NightstandScreen.menu(title, list, current, on_pick, mark)
    local items = {}
    for _index, spec in ipairs(list) do
        local chosen = spec.id == current
        table.insert(items, {
            text = spec.label .. (chosen and mark or ""),
            checked = chosen,
            callback = function() on_pick(spec) end,
        })
    end
    require("dialogs").menu{ title = title, items = items }
end

NightstandScreen.VIEWS = {
    { id = "grid", label = _("Grid") },
    { id = "list", label = _("List") },
}

--- The grid/list choice, remembered under `self.view_setting`.
function NightstandScreen:loadView()
    self.view = Settings:get(self.view_setting) == "list" and "list" or "grid"
end

function NightstandScreen:chooseView()
    NightstandScreen.menu(_("View"), NightstandScreen.VIEWS, self.view, function(spec)
        if spec.id == self.view then return end
        self.view, self.page = spec.id, 1
        Settings:set(self.view_setting, spec.id)
        self:refresh()
    end)
end

function NightstandScreen:viewLabel()
    return self.view == "list" and _("List") or _("Grid")
end

function NightstandScreen:tabsBand(h, band_y)
    return TabBar.build(self.screen_w, h, band_y, self.tab_id,
                        function(...) self:zone(...) end,
                        function(id) self:onTab(id) end)
end

--- Home stays underneath everything; any other tab replaces the one on top.
function NightstandScreen:onTab(id)
    if id == self.tab_id then return self:onTabAgain() end
    if self.tab_id ~= "home" then UIManager:close(self) end
    if id ~= "home" and self.plugin then self.plugin:openTab(id) end
end

--- Tapping the tab you are already on.
function NightstandScreen:onTabAgain() end

function NightstandScreen:onClose()
    UIManager:close(self)
    return true
end

function NightstandScreen:onCloseWidget()
    NightstandScreen.open_screens[self] = nil
    if self[1] then self[1]:free() end
    if self.on_closed then self.on_closed() end
    UIManager:setDirty(nil, "full")
end

return NightstandScreen
