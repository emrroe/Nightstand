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
shoot(require("homescreen"):new{ plugin = plugin }, "home")
shoot(require("libraryscreen"):new{ plugin = plugin }, "library")
shoot(require("settingsscreen"):new{ plugin = plugin }, "settings")
if os.getenv("SNAP_DISCOVER") then
    shoot(require("discoverscreen"):new{ plugin = plugin }, "discover")
end
print("snapshots written for " .. label)
T.finish()
