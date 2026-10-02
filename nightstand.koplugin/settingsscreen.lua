--[[--
Nightstand's own settings, as a full screen rather than a drop-down.

KOReader's TouchMenu hides each value inside its label and only uses the top
two thirds of the screen. This shows one row per setting with its value on the
right, and keeps the footer tabs so Settings is a place rather than a popup.
The last row hands over to KOReader's own menu for everything else.
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
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local Availability = require("availability")
local Catalog = require("catalog")
local Hardcover = require("hardcover")
local HardcoverLink = require("hardcoverlink")
local Settings = require("settings")
local TabBar = require("tabbar")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GREY = Blitbuffer.COLOR_GRAY

local SettingsScreen = InputContainer:extend{
    name = "nightstand_settings",
    covers_fullscreen = true,
}

local function text(str, face, size, colour, max_width)
    return TextWidget:new{
        text = str or "",
        face = Font:getFace(face, size),
        fgcolor = colour or BLACK,
        max_width = max_width,
    }
end

local function box(w, h)
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, VerticalSpan:new{ width = 0 } }
end

--- Filled with the knob right for on, outlined with it left for off: two cues,
--- neither of them colour.
local function toggle(on)
    local h = Screen:scaleBySize(19)
    local w = math.floor(h * 1.9)
    local knob = h - Screen:scaleBySize(7)
    local inset = math.floor((h - knob) / 2)

    local track = FrameContainer:new{
        background = on and BLACK or WHITE,
        color = BLACK,
        bordersize = Size.border.thin,
        padding = 0, margin = 0,
        radius = math.floor(h / 2),
        box(w, h),
    }
    local dot = FrameContainer:new{
        background = on and WHITE or BLACK,
        bordersize = 0, padding = 0, margin = 0,
        radius = math.floor(knob / 2),
        box(knob, knob),
    }
    local size = track:getSize()
    dot.overlap_offset = {
        on and (size.w - knob - inset - Size.border.thin) or (inset + Size.border.thin),
        inset + Size.border.thin,
    }
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = size.w, h = size.h },
        allow_mirroring = false,
    }
    table.insert(group, track)
    table.insert(group, dot)
    return group
end

function SettingsScreen:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.gutter = math.floor(self.screen_w * 0.023)
    self.tap_zones = {}

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = full } }
    end
    self:build()
end

function SettingsScreen:zone(x, y, w, h, callback)
    table.insert(self.tap_zones, { rect = Geom:new{ x = x, y = y, w = w, h = h }, cb = callback })
end

function SettingsScreen:groups()
    local plugin = self.plugin
    local books_dir = Settings:booksDir()
    return {
        { _("Library"), {
            { label = _("Server"), value = Settings:get("server"),
              action = function() plugin:editServer() end },
            { label = _("Books folder"),
              value = books_dir ~= "" and books_dir or _("not set"),
              action = function() plugin:editServer() end },
            { label = _("Refresh catalogue"),
              value = T(_("%1 books"), Catalog:count()),
              action = function() plugin:refreshCatalogue() self:rebuild() end },
            { label = _("Refresh when the device wakes"), key = "refresh_on_wake" },
        }},
        { _("Hardcover"), {
            self:hardcoverRow(),
        }},
        { _("Home screen"), {
            { label = _("Layout"), value = Settings:layoutName(),
              action = function() self:cycleLayout() end },
            { label = _("Show time remaining"), key = "time_remaining" },
        }},
        { _("Downloads"), {
            { label = _("Over Wi-Fi only"), key = "wifi_only" },
            { label = _("Delete the file when a book is finished"),
              key = "delete_when_finished" },
        }},
        { _("This device"), {
            { label = _("Books held locally"),
              value = T(_("%1 of %2"), Availability:count(), Catalog:count()),
              action = function()
                  Availability:invalidate()
                  Availability:ensure(books_dir)
                  self:rebuild()
              end },
            { label = _("All KOReader settings"), chevron = true,
              action = function() plugin:openKoreaderMenu() end },
        }},
    }
end

function SettingsScreen:hardcoverRow()
    if not Hardcover:isAvailable() then
        return { label = _("Account"), value = _("not available in this build") }
    end
    if Hardcover:isLinked() then
        local name = Hardcover:username()
        return { label = _("Account"), value = name and ("@" .. name) or _("connected"),
                 action = function() self:confirmUnlink() end }
    end
    return { label = _("Account"), value = _("Connect ›"),
             action = function() self:openLink() end }
end

function SettingsScreen:openLink()
    NetworkMgr:runWhenOnline(function()
        UIManager:show(HardcoverLink:new{
            on_linked = function() self:rebuild() end,
        })
    end)
end

function SettingsScreen:confirmUnlink()
    UIManager:show(ConfirmBox:new{
        text = T(_("Disconnect Hardcover account @%1 from this device?"), Hardcover:username() or "?"),
        ok_text = _("Disconnect"),
        ok_callback = function()
            -- offline, the token is only forgotten; it lapses on Hardcover's side
            if NetworkMgr:isOnline() then Hardcover:unlink() else Hardcover:forget() end
            self:rebuild()
        end,
    })
end

function SettingsScreen:cycleLayout()
    local current = Settings:get("layout")
    local layouts = Settings.LAYOUTS
    for index, layout in ipairs(layouts) do
        if layout.id == current then
            Settings:set("layout", layouts[index % #layouts + 1].id)
            break
        end
    end
    self:rebuild()
end

function SettingsScreen:rebuild()
    self.tap_zones = {}
    self:build()
    UIManager:setDirty(self, "ui")
end

function SettingsScreen:build()
    local w, h = self.screen_w, self.screen_h
    local tabs_h = TabBar.height()
    local tabs_margin = TabBar.margin()
    local row_h = Screen:scaleBySize(34)
    local header_h = Screen:scaleBySize(30)

    local y = 0
    local stack = VerticalGroup:new{ align = "left" }
    local function add(widget, height)
        table.insert(stack, widget)
        y = y + height
    end

    -- title
    local title_h = Screen:scaleBySize(42)
    add(LeftContainer:new{
        dimen = Geom:new{ w = w, h = title_h },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = self.gutter },
            text(_("Settings"), "NotoSerif-Bold.ttf", 20),
        },
    }, title_h)
    add(LineWidget:new{ background = GREY, dimen = Geom:new{ w = w, h = Size.line.thin } },
        Size.line.thin)

    for _index, group in ipairs(self:groups()) do
        local title, rows = group[1], group[2]
        add(LeftContainer:new{
            dimen = Geom:new{ w = w, h = header_h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = self.gutter },
                text(title:upper(), "infont", 10, GREY),
            },
        }, header_h)

        for _i, row in ipairs(rows) do
            add(self:rowBand(row, row_h, y), row_h)
            add(LineWidget:new{
                    background = GREY,
                    dimen = Geom:new{ w = w, h = Size.line.thin } },
                Size.line.thin)
        end
    end

    -- push the tabs to the bottom
    local filler = h - y - tabs_h - tabs_margin
    if filler > 0 then add(VerticalSpan:new{ width = filler }, filler) end
    add(VerticalSpan:new{ width = tabs_margin }, tabs_margin)

    local tabs_y = y
    add(TabBar.build(w, tabs_h, tabs_y, "settings",
                     function(...) self:zone(...) end,
                     function(id) self:onTab(id) end), tabs_h)

    self[1] = FrameContainer:new{
        width = w, height = h, background = WHITE,
        bordersize = 0, padding = 0, margin = 0,
        stack,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

function SettingsScreen:rowBand(row, h, band_y)
    local w = self.screen_w
    local right
    if row.key ~= nil then
        right = toggle(Settings:get(row.key))
    elseif row.chevron then
        right = text("›", "infont", 16, GREY)
    else
        right = text(row.value, "infont", 12, GREY,
                     math.floor(w * 0.45))
    end
    local right_w = right:getSize().w
    local label_w = w - 2 * self.gutter - right_w - Size.padding.large

    local action = row.action
    if action then
        self:zone(0, band_y, w, h, action)
    elseif row.key then
        local key = row.key
        self:zone(0, band_y, w, h, function()
            Settings:toggle(key)
            self:rebuild()
        end)
    end

    return LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = self.gutter },
            LeftContainer:new{
                dimen = Geom:new{ w = label_w, h = h },
                text(row.label, "cfont", 13, BLACK, label_w),
            },
            RightContainer:new{
                dimen = Geom:new{ w = right_w + Size.padding.large, h = h },
                right,
            },
            HorizontalSpan:new{ width = self.gutter },
        },
    }
end

function SettingsScreen:onTab(id)
    if id == "settings" then return end
    UIManager:close(self)
    if id ~= "home" then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("That tab is next on the list."),
            timeout = 2,
        })
    end
end

function SettingsScreen:onTap(_widget, ges)
    for _index, zone in ipairs(self.tap_zones) do
        if zone.rect:contains(ges.pos) then
            zone.cb()
            return true
        end
    end
    return true
end

function SettingsScreen:onClose()
    UIManager:close(self)
    return true
end

function SettingsScreen:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

return SettingsScreen
