--[[--
A book cover at a given size, with its two corner marks: progress (or a tag
the entry brings) top right, a round download badge bottom right for books
that are only on the server. Books without a cover get their title on a card.
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Books = require("books")
local CoverCache = require("covercache")
local Dim = require("dim")
local W = require("widgets")
local text = W.text
local BLACK, WHITE, GREY, BOLD = W.BLACK, W.WHITE, W.GREY, W.BOLD

local CoverTile = {}

local function placeholder(entry, w, h)
    local border = Size.border.thin
    local pad = Dim.pad.small
    local inner_w = w - 2 * border - 2 * pad
    local inner_h = h - 2 * border - 2 * pad
    -- small enough that no word of the title has to break
    local size = 13
    local longest = ""
    for word in entry.title:gmatch("%S+") do
        if #word > #longest then longest = word end
    end
    while size > 8 do
        local probe = W.text(longest, BOLD, size)
        local fits = probe:getSize().w <= inner_w
        probe:free()
        if fits then break end
        size = size - 1
    end
    local function title(cap)
        return TextBoxWidget:new{
            text = entry.title, face = Dim.face(BOLD, size),
            width = inner_w, alignment = "center",
            height = cap, height_overflow_show_ellipsis = cap ~= nil,
        }
    end
    -- a title longer than the cover is cut, not spilled; short ones stay centred
    local label = title()
    if label:getSize().h > inner_h then
        label:free()
        label = title(inner_h)
    end
    return FrameContainer:new{
        background = WHITE, color = GREY, bordersize = border,
        padding = pad, margin = 0, radius = 0,
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, label },
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
    if tag then
        -- progress is inverted so it stands out; labels stay outlined
        local solid = kind == "progress"
        local badge = FrameContainer:new{
            background = solid and BLACK or WHITE,
            color = BLACK,
            bordersize = solid and 0 or Size.border.thin,
            padding = Dim.pad.tiny,
            padding_left = Dim.pad.small + Dim.pad.tiny, padding_right = Dim.pad.small + Dim.pad.tiny,
            margin = 0,
            radius = Dim.px(3),
            text(tag, BOLD, 9.5, solid and WHITE or BLACK),
        }
        badge.overlap_offset = { w - badge:getSize().w - pad, pad }
        table.insert(group, badge)
    end

    if not entry.on_device then
        local size = math.min(Dim.px(22), math.max(Dim.px(15), math.floor(w * 0.2)))
        local badge = W.icon("download", nil, size)
        badge.overlap_offset = { w - size - pad, h - size - pad }
        table.insert(group, badge)
    end

    return group
end

return CoverTile
