--[[--
A book cover at a given size, with its two corner marks: progress (or a tag
the entry brings) top right, a round download badge bottom right for books
that are only on the server. Books without a cover get their title on a card.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Books = require("books")
local CoverCache = require("covercache")
local Dim = require("dim")
local W = require("widgets")
local text = W.text
local BLACK, WHITE, GREY, BOLD = W.BLACK, W.WHITE, W.GREY, W.BOLD
-- the light grey of a cover-less book
local PAPER = Blitbuffer.Color8(0xE8)

local CoverTile = {}

--- A cover for a book without one: light grey, the title in bold in its
--- upper part, a short rule, and the author below -- laid out like a cover
--- rather than a missing image.
local function placeholder(entry, w, h)
    local pad = math.max(Dim.pad.small, math.floor(w * 0.08))
    local inner_w = w - 2 * pad
    -- small enough that no word of the title has to break
    local size = math.max(9, math.min(15, math.floor(w / Dim.px(7))))
    local longest = ""
    for word in (entry.title or ""):gmatch("%S+") do
        if #word > #longest then longest = word end
    end
    while size > 8 do
        local probe = W.text(longest, BOLD, size)
        local fits = probe:getSize().w <= inner_w
        probe:free()
        if fits then break end
        size = size - 1
    end
    local title_h = math.floor(h * 0.62) - pad
    local title = TextBoxWidget:new{
        text = entry.title or "", face = Dim.face(BOLD, size), fgcolor = BLACK, bgcolor = PAPER,
        width = inner_w, alignment = "center",
        height = title_h, height_overflow_show_ellipsis = true, height_adjust = true,
    }
    local column = VerticalGroup:new{ align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = title_h }, title },
        VerticalSpan:new{ width = Dim.pad.default },
        LineWidget:new{ background = BLACK, dimen = Geom:new{ w = math.floor(inner_w * 0.3), h = Size.line.medium } },
    }
    if entry.author and entry.author ~= "" then
        table.insert(column, VerticalSpan:new{ width = Dim.pad.default })
        table.insert(column, TextBoxWidget:new{
            text = entry.author, face = Dim.face(W.REGULAR, math.max(8, size - 3)), fgcolor = W.MUTED,
            bgcolor = PAPER, width = inner_w, alignment = "center",
            height = math.floor(h * 0.2), height_overflow_show_ellipsis = true, height_adjust = true,
        })
    end
    return FrameContainer:new{
        background = PAPER, bordersize = 0, padding = 0, margin = 0,
        radius = math.floor(w * 0.045),
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, column },
    }
end

function CoverTile.new(entry, w, h, opts)
    opts = opts or {}
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        allow_mirroring = false,
    }
    local bb = CoverCache:get(entry, w, h)
    if bb then
        table.insert(group, ImageWidget:new{
            image = bb, image_disposable = false, width = w, height = h,
        })
    else
        table.insert(group, placeholder(entry, w, h))
    end

    local pad = math.max(2, math.floor(w * 0.04))
    local tag, kind
    if not opts.no_tag then
        -- an entry can bring its own tag (Discover's "In library"), or none
        if entry.tag ~= nil then tag = entry.tag or nil else tag, kind = Books:progressTag(entry) end
    end
    if kind == "new" and opts.hide_new then tag = nil end
    local badge_size = math.min(Dim.px(22), math.max(Dim.px(15), math.floor(w * 0.2)))
    if kind == "progress" then
        -- progress is a thin bar along the cover's foot, on a white strip so
        -- it reads on dark and light covers alike; it stops short of the badge
        local bar_w = w - 2 * pad - (entry.on_device and 0 or badge_size + pad)
        local bar_h = math.max(Dim.px(4), math.floor(w * 0.035))
        local strip = FrameContainer:new{
            background = WHITE, bordersize = 0, padding = Size.border.thin, margin = 0,
            radius = math.floor(bar_h / 2) + Size.border.thin,
            W.progress(bar_w, entry.percent or 0, bar_h),
        }
        local strip_h = strip:getSize().h
        local badge_mid = entry.on_device and 0 or math.floor((badge_size - strip_h) / 2)
        strip.overlap_offset = { pad, h - pad - strip_h - badge_mid }
        table.insert(group, strip)
    elseif tag then
        -- other labels (Finished, a tag the entry brings) stay outlined
        local label = FrameContainer:new{
            background = WHITE, color = BLACK, bordersize = Size.border.thin,
            padding = Dim.pad.tiny,
            padding_left = Dim.pad.small + Dim.pad.tiny, padding_right = Dim.pad.small + Dim.pad.tiny,
            margin = 0, radius = Dim.px(3),
            text(tag, BOLD, 9.5, BLACK),
        }
        label.overlap_offset = { w - label:getSize().w - pad, pad }
        table.insert(group, label)
    end

    if not entry.on_device then
        local badge = W.icon("download", nil, badge_size)
        badge.overlap_offset = { w - badge_size - pad, h - badge_size - pad }
        table.insert(group, badge)
    end

    return group
end

return CoverTile
