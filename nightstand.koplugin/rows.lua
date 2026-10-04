--[[--
A page of list rows: a cover with the title, author, a facts line and as
much of a description as fits beside it. Rows share out the whole height;
landscape screens get two columns of them.
--]]--

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local CoverTile = require("covertile")
local Dim = require("dim")
local W = require("widgets")

local BLACK, GREY, SERIF = W.BLACK, W.GREY, W.SERIF

local Rows = {}

--- Columns, rows and row height for `w` x `h`.
function Rows.plan(w, h)
    local columns = w > h and 2 or 1
    local min_h = W.coverHeight(Dim.px(64)) + 2 * Dim.pad.default
    local rows = math.max(1, math.floor(h / min_h))
    return { columns = columns, rows = rows, row_h = math.floor(h / rows),
             col_w = math.floor(w / columns), per_page = columns * rows }
end

--- One page of `items`; columns fill top to bottom. `row(item, w, h)` draws one.
function Rows.page(items, first, plan, w, band_y, zone, on_tap, on_hold, row)
    local columns = HorizontalGroup:new{ align = "top" }
    for c = 1, plan.columns do
        local column = VerticalGroup:new{ align = "left" }
        for r = 1, plan.rows do
            local item = items[first + (c - 1) * plan.rows + r - 1]
            if not item then break end
            table.insert(column, row(item, plan.col_w, plan.row_h))
            zone((c - 1) * plan.col_w, band_y + (r - 1) * plan.row_h, plan.col_w, plan.row_h,
                 function() on_tap(item) end, on_hold and function() on_hold(item) end)
        end
        table.insert(columns, column)
    end
    local h = plan.rows * plan.row_h
    return TopContainer:new{ dimen = Geom:new{ w = w, h = h }, columns }
end

local function box(str, face, size, colour, width, lines)
    return TextBoxWidget:new{
        text = str, face = Dim.face(face, size), fgcolor = colour, width = width,
        height = lines * W.lineHeight(face, size), height_overflow_show_ellipsis = true,
    }
end

--- A row of `w` x `h`, inset by `gutter`. `spec` holds the cover entry and
--- the text: `title`, `author`, `facts` (a list, joined with dots) and `blurb`.
function Rows.row(spec, w, h, gutter)
    local pad = Dim.pad.default
    local cover_h = h - 2 * pad - Size.line.thin
    local cover_w = math.min(math.floor(cover_h / W.COVER_ASPECT), math.floor(w * 0.3))
    local text_w = w - 2 * gutter - cover_w - gutter
    local room = cover_h

    local col = VerticalGroup:new{ align = "left" }
    local function put(widget)
        table.insert(col, widget)
        room = room - widget:getSize().h
    end
    local function lines(face, size)
        return math.floor(room / W.lineHeight(face, size))
    end
    local function fits(str, face, size)
        local probe = TextBoxWidget:new{ text = str, face = Dim.face(face, size), width = text_w }
        local n = math.ceil(probe:getSize().h / W.lineHeight(face, size))
        probe:free()
        return n
    end

    -- the title gets a second line only if it needs one and the row has room
    local title_lines = math.max(1, math.min(2, fits(spec.title, SERIF, 15), lines(SERIF, 15) - 1))
    put(box(spec.title, SERIF, 15, BLACK, text_w, title_lines))
    if spec.author and spec.author ~= "" and lines("cfont", 12) >= 1 then
        put(W.text(spec.author, "cfont", 12, GREY, text_w))
    end
    if spec.facts and #spec.facts > 0 and lines("infont", 11) >= 1 then
        -- the dot is held to the fact before it, so a wrapped line never starts with one
        local kept = {}
        for i, fact in ipairs(spec.facts) do kept[i] = fact:gsub(" ", "\u{00A0}") end
        local facts = table.concat(kept, "\u{00A0}·  ")
        put(box(facts, "infont", 11, BLACK, text_w,
                math.min(2, fits(facts, "infont", 11), lines("infont", 11))))
    end
    if spec.blurb and spec.blurb ~= "" and lines("cfont", 12) >= 1 then
        put(box(spec.blurb, "cfont", 12, GREY, text_w, lines("cfont", 12)))
    end

    return VerticalGroup:new{
        align = "left",
        LeftContainer:new{
            dimen = Geom:new{ w = w, h = h - Size.line.thin },
            HorizontalGroup:new{
                align = "top",
                W.hspan(gutter),
                CoverTile.new(spec.cover, cover_w, cover_h, spec.cover_opts),
                W.hspan(gutter),
                col,
            },
        },
        W.rule(w),
    }
end

return Rows
