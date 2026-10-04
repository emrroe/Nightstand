--[[--
A page of covers that fills its whole area.

Columns come from the width (covers about 21 mm wide, at least four across),
rows from the height, and every cell is then stretched to share the area out
exactly -- the covers are cropped to their cell, never squashed, so a cell a
little off the 2:3 book shape costs a sliver of cover art rather than a band
of empty screen.
--]]--

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CoverTile = require("covertile")
local Dim = require("dim")
local W = require("widgets")

local CoverGrid = {}

-- cells further than this from 2:3 would crop too much of the cover
local MIN_ASPECT, MAX_ASPECT = 1.3, 1.7

--- Columns, rows and cell size for `w` x `h`. The layout never depends on
--- how many books there are: a short page leaves its end empty.
function CoverGrid.plan(w, h)
    local gap = W.GAP
    local cols = math.max(4, math.floor((w + gap) / (Dim.px(100) + gap) + 0.5))
    local best
    for c = cols, cols + 3 do
        local cell_w = math.floor((w - (c - 1) * gap) / c)
        local rows = math.max(1, math.floor((h + gap) / (W.coverHeight(cell_w) + gap) + 0.5))
        local cell_h = math.floor((h - (rows - 1) * gap) / rows)
        local aspect = cell_h / cell_w
        local plan = { cols = c, rows = rows, cell_w = cell_w, cell_h = cell_h, gap = gap,
                       off = math.abs(aspect - W.COVER_ASPECT) }
        if aspect >= MIN_ASPECT and aspect <= MAX_ASPECT then return plan end
        if not best or plan.off < best.off then best = plan end
    end
    return best
end

--- One page of `items` laid out to `plan`, starting at screen y `band_y`.
--- `zone(x, y, w, h, on_tap, on_hold)` registers each cell's tap target;
--- `tile(item, w, h)` draws one cell (a book cover by default).
function CoverGrid.page(items, first, plan, w, band_y, zone, on_tap, on_hold, tile)
    tile = tile or function(item, cw, ch) return CoverTile.new(item, cw, ch, { hide_new = true }) end
    local x0 = math.floor((w - (plan.cols * plan.cell_w + (plan.cols - 1) * plan.gap)) / 2)
    local grid = VerticalGroup:new{ align = "left" }
    for row = 1, plan.rows do
        local line = HorizontalGroup:new{ align = "top", W.hspan(x0) }
        for col = 1, plan.cols do
            local item = items[first + (row - 1) * plan.cols + (col - 1)]
            if col > 1 then table.insert(line, W.hspan(plan.gap)) end
            if item then
                table.insert(line, tile(item, plan.cell_w, plan.cell_h))
                zone(x0 + (col - 1) * (plan.cell_w + plan.gap),
                     band_y + (row - 1) * (plan.cell_h + plan.gap),
                     plan.cell_w, plan.cell_h,
                     function() on_tap(item) end,
                     on_hold and function() on_hold(item) end)
            else
                table.insert(line, W.hspan(plan.cell_w))
            end
        end
        table.insert(grid, line)
        if row < plan.rows then table.insert(grid, VerticalSpan:new{ width = plan.gap }) end
    end
    local h = plan.rows * plan.cell_h + (plan.rows - 1) * plan.gap
    return TopContainer:new{ dimen = Geom:new{ w = w, h = h }, grid }
end

return CoverGrid
