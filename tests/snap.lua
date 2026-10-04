--[[--
Renders Nightstand's screens to PNG files, for looking at a layout on a
device size the desktop can't show. Driven by snap.sh.
--]]--

local T = require("t")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen

local out = assert(os.getenv("SNAP_OUT"))
local label = os.getenv("SIZE_LABEL") or "screen"
local W, H = Screen:getWidth(), Screen:getHeight()

local function shoot(widget, name)
    local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BBRGB32)
    bb:fill(Blitbuffer.COLOR_WHITE)
    widget:paintTo(bb, 0, 0)
    bb:writePNG(string.format("%s/%s-%s.png", out, label, name))
    bb:free()
end

local plugin = setmetatable({}, { __index = function() return function() end end })
shoot(require("homescreen"):new{ plugin = plugin }, "1-home")

local library = require("libraryscreen"):new{ plugin = plugin }
shoot(library, "2-library")
if library.pages > 1 then
    library:turnPage(1)
    shoot(library, "3-library-page2")
end
library.view, library.page = "list", 1
library:refresh()
shoot(library, "2b-library-list")
library.view = "grid"
library.group, library.page = "series", 1
library:refresh()
shoot(library, "4-library-series")
if library.showing_groups and library.items[1] then
    -- the largest series makes the more telling picture
    local biggest = library.items[1]
    for _, group in ipairs(library.items) do
        if #group.books > #biggest.books then biggest = group end
    end
    library:activate(biggest)
    shoot(library, "5-library-series-open")
end

if os.getenv("SNAP_DISCOVER") then
    local discover = require("discoverscreen"):new{ plugin = plugin }
    discover:showList("recs")
    shoot(discover, "6-discover")
    discover.view = discover.view == "list" and "grid" or "list"
    discover:refresh()
    shoot(discover, "6b-discover-" .. discover.view)
    discover.view = "list"
    discover:showList("top")
    shoot(discover, "7-discover-top")
    discover:showList("want")
    shoot(discover, "8-discover-want")
end
shoot(require("settingsscreen"):new{ plugin = plugin }, "9-settings")
print("snapshots written for " .. label)
T.finish()
