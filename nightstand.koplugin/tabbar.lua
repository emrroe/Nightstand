--[[--
The footer tab strip, shared by every full-screen Nightstand view so the two
can never drift apart.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local Screen = Device.screen

local TabBar = {
    TABS = {
        { id = "home",     label = "HOME" },
        { id = "library",  label = "LIBRARY" },
        { id = "settings", label = "SETTINGS" },
    },
}

--- Chrome, not content: one height whatever the orientation.
function TabBar.height()
    return Screen:scaleBySize(40)
end

function TabBar.margin()
    return Screen:scaleBySize(16)
end

--- `zone(x, y, w, h, callback)` registers a tap target with the caller.
function TabBar.build(screen_w, h, band_y, active_id, zone, on_tab)
    local tab_w = math.floor(screen_w / #TabBar.TABS)
    local marker_h = math.floor(h * 0.08)
    local strip = HorizontalGroup:new{ align = "top" }

    for index, tab in ipairs(TabBar.TABS) do
        local active = tab.id == active_id
        local cell = VerticalGroup:new{ align = "center" }
        if active then
            table.insert(cell, LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = tab_w, h = marker_h },
            })
        end
        table.insert(cell, CenterContainer:new{
            -- the rule above the strip is part of the bar's height
            dimen = Geom:new{ w = tab_w, h = h - marker_h - Size.line.thin },
            TextWidget:new{
                text = _(tab.label),
                face = Font:getFace("infont", 11),
                fgcolor = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            },
        })
        table.insert(strip, cell)
        local id = tab.id
        zone((index - 1) * tab_w, band_y, tab_w, h, function() on_tab(id) end)
    end

    return VerticalGroup:new{
        align = "left",
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = screen_w, h = Size.line.thin },
        },
        strip,
    }
end

return TabBar
