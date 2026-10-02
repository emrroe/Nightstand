--[[--
The footer tab strip, shared by every full-screen Nightstand view so the two
can never drift apart.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Dim = require("dim")
local _ = require("gettext")
local Screen = Device.screen

local TabBar = {
    TABS = {
        { id = "home",     label = _("HOME") },
        { id = "library",  label = _("LIBRARY") },
        { id = "discover", label = _("DISCOVER"), needs_hardcover = true },
        { id = "settings", label = _("SETTINGS") },
    },
}

--- The tabs to show right now: Discover only once Hardcover is connected.
function TabBar.tabs()
    local linked = require("hardcover"):isLinked()
    local out = {}
    for _index, tab in ipairs(TabBar.TABS) do
        if linked or not tab.needs_hardcover then table.insert(out, tab) end
    end
    return out
end

--- Chrome, not content: one height whatever the orientation.
function TabBar.height()
    return Dim.px(40)
end

function TabBar.margin()
    return Dim.px(16)
end

--- `zone(x, y, w, h, callback)` registers a tap target with the caller.
function TabBar.build(screen_w, h, band_y, active_id, zone, on_tab)
    local tabs = TabBar.tabs()
    local tab_w = math.floor(screen_w / #tabs)
    local marker_h = math.floor(h * 0.08)
    local strip = HorizontalGroup:new{ align = "top" }

    for index, tab in ipairs(tabs) do
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
                text = tab.label,
                face = Dim.face("infont", 11),
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
