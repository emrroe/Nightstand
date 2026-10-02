--[[--
Physical sizing for Nightstand's own screens.

KOReader's scaleBySize grows with the screen's pixel width and ignores DPI
unless the user overrides it, so a dense phone (1080 px at ~410 ppi) draws
everything at about half the physical size of a Nova 2 (1404 px at 300 ppi).
Sizes here follow DPI instead, calibrated so the Nova 2 looks exactly as it
did under scaleBySize.
--]]--

local Device = require("device")
local Font = require("ui/font")
local Screen = Device.screen

-- On a 1404 px, 300 dpi panel scaleBySize multiplies by 1404/600; at 300 dpi
-- a plain DPI scale is 300/160. Their ratio carries that look to any screen.
local CALIBRATION = (1404 / 600) / (300 / 160)

local Dim = {}

local function factor()
    return Screen:getDPI() / 160 * CALIBRATION
end

--- A length in Nightstand's units, as device pixels.
function Dim.px(dp)
    return math.max(1, math.floor(dp * factor() + 0.5))
end

--- A font face at a physical size. Font:getFace applies scaleBySize to the
--- size it is given, so this hands it whatever undoes that.
function Dim.face(name, dp)
    local by_size = Screen:scaleBySize(1000) / 1000
    return Font:getFace(name, dp * factor() / by_size)
end

-- KOReader's Size.padding values, but physical.
Dim.pad = {
    tiny = Dim.px(1),
    small = Dim.px(2),
    default = Dim.px(5),
    large = Dim.px(10),
}

return Dim
