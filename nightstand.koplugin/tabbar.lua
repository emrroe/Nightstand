--[[--
The footer tab strip, shared by every full-screen Nightstand view so the two
can never drift apart.
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Dim = require("dim")
local W = require("widgets")
local _ = require("gettext")

local TabBar = {
    TABS = {
        { id = "home",     label = _("Home") },
        { id = "library",  label = _("Library") },
        { id = "discover", label = _("Discover"), needs_hardcover = true },
        { id = "settings", label = _("Settings") },
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
    return Dim.px(52)
end

function TabBar.margin()
    return Dim.px(6)
end

--- An icon over a label; the active tab is bold, with a bar along its top.
--- `zone(x, y, w, h, callback)` registers a tap target with the caller.
function TabBar.build(screen_w, h, band_y, active_id, zone, on_tab)
    local tabs = TabBar.tabs()
    local tab_w = math.floor(screen_w / #tabs)
    local bar = Dim.px(3)
    local strip = HorizontalGroup:new{ align = "top" }

    for index, tab in ipairs(tabs) do
        local active = tab.id == active_id
        table.insert(strip, VerticalGroup:new{
            align = "center",
            LineWidget:new{
                background = active and W.BLACK or W.WHITE,
                dimen = Geom:new{ w = tab_w, h = bar },
            },
            CenterContainer:new{
                -- the rule above the strip is part of the bar's height
                dimen = Geom:new{ w = tab_w, h = h - bar - Size.line.thin },
                VerticalGroup:new{
                    align = "center",
                    W.icon("tab-" .. tab.id .. (active and "-on" or "-off"), 20),
                    VerticalSpan:new{ width = Dim.px(2) },
                    W.text(tab.label, active and W.BOLD or W.REGULAR, 9.5, active and W.BLACK or W.MUTED),
                },
            },
        })
        local id = tab.id
        zone((index - 1) * tab_w, band_y, tab_w, h, function() on_tab(id) end)
    end

    return VerticalGroup:new{
        align = "left",
        W.rule(screen_w),
        strip,
    }
end

return TabBar
