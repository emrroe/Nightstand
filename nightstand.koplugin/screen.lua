--[[--
Base for Nightstand's full-screen views.

A screen is built from bands stacked top to bottom; while building, each band
registers the tap zones it draws, so taps are resolved against geometry the
screen computed itself rather than against widget hit-testing. Subclasses
supply `load` (gather data) and `build` (lay out and register zones), and set
`tab_id` to light up their tab.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Dim = require("dim")
local Settings = require("settings")
local TabBar = require("tabbar")
local W = require("widgets")
local _ = require("gettext")
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
    table.insert(self.tap_zones, { rect = Geom:new{ x = x, y = y, w = w, h = h },
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

--- A header control that opens a menu: grey label, value, and a mark.
function NightstandScreen.control(label, value, mark)
    local group = HorizontalGroup:new{ align = "center" }
    if label then
        table.insert(group, W.text(label, "infont", 11, W.GREY))
        table.insert(group, W.hspan(Dim.pad.large))
    end
    table.insert(group, W.text(value .. " " .. mark, "infont", 12, W.BLACK))
    return group
end

--- A menu of options with the current one ticked (`mark` is added after it).
function NightstandScreen.menu(title, list, current, on_pick, mark)
    local buttons = {}
    local dialog
    for _index, spec in ipairs(list) do
        local label = spec.label
        if spec.id == current then label = "✓  " .. label .. (mark or "") end
        table.insert(buttons, {{
            text = label,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                on_pick(spec)
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
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
