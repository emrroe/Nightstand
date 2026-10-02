--[[--
Cover thumbnails.

Local books get their cover extracted from the file; server-only books get
theirs fetched once and kept as a jpeg on disk, because CWA serves the full
cover at the thumbnail URL too -- book 2's is 1.4 MB, so refetching per paint
is not an option.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local CoverCache = {
    cache = {},   -- "key|WxH" -> BlitBuffer
    misses = {},  -- key -> true, for books with no usable cover
}

local function cacheDir()
    local dir = DataStorage:getDataDir() .. "/cache/nightstand"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(dir)
    end
    return dir
end

function CoverCache:coverFile(book_id)
    return cacheDir() .. "/" .. tostring(book_id) .. ".jpg"
end

function CoverCache:hasRemote(book_id)
    return book_id ~= nil
       and lfs.attributes(self:coverFile(book_id), "mode") == "file"
end

--- Fetch and store one cover. Slow and network-bound, so callers do this in a
--- deliberate refresh rather than while painting.
function CoverCache:fetchRemote(book_id, cover_url)
    if not book_id or not cover_url then return false end
    if self:hasRemote(book_id) then return true end
    local Catalog = require("catalog")
    local body = Catalog:get(cover_url)
    if not body then return false end
    local file = io.open(self:coverFile(book_id), "wb")
    if not file then return false end
    file:write(body)
    file:close()
    return true
end

--- Whites out the pixels outside a rounded rectangle. Done once per cached
--- thumbnail, so it costs nothing at paint time.
local function roundCorners(bb, radius)
    if not bb or not radius or radius < 2 then return bb end
    local w, h = bb:getWidth(), bb:getHeight()
    local white = Blitbuffer.COLOR_WHITE
    local limit = radius * radius
    for dy = 0, radius - 1 do
        for dx = 0, radius - 1 do
            local ox, oy = radius - dx - 0.5, radius - dy - 0.5
            if ox * ox + oy * oy > limit then
                bb:setPixel(dx, dy, white)
                bb:setPixel(w - 1 - dx, dy, white)
                bb:setPixel(dx, h - 1 - dy, white)
                bb:setPixel(w - 1 - dx, h - 1 - dy, white)
            end
        end
    end
    return bb
end

local function scaled(key, cache, loader, width, height)
    local slot = string.format("%s|%dx%d", key, width, height)
    if cache.cache[slot] then return cache.cache[slot] end
    if cache.misses[key] then return nil end
    local bb = loader()
    if not bb then
        cache.misses[key] = true
        return nil
    end
    cache.cache[slot] = bb
    return bb
end

--- A cover for an entry, from the local file or the fetched jpeg.
function CoverCache:get(entry, width, height)
    if not entry or not width or not height then return nil end
    width, height = math.floor(width), math.floor(height)

    if entry.file then
        return scaled(entry.file, self, function()
            local ok, bb = pcall(BookInfo.getCoverImage, BookInfo, nil, entry.file)
            if not ok or not bb then return nil end
            return roundCorners(RenderImage:scaleBlitBuffer(bb, width, height, true),
                                math.floor(width * 0.045))
        end, width, height)
    end

    if entry.hc_id then
        local Discover = require("discover")
        if not Discover:hasCover(entry.hc_id, entry.image_url) then return nil end
        return scaled("hc:" .. entry.hc_id, self, function()
            local ok, bb = pcall(function()
                return RenderImage:renderImageFile(Discover:coverFile(entry.hc_id, entry.image_url),
                                                   false, width, height)
            end)
            if not ok or not bb then return nil end
            return roundCorners(RenderImage:scaleBlitBuffer(bb, width, height, true),
                                math.floor(width * 0.045))
        end, width, height)
    end

    if entry.book_id and self:hasRemote(entry.book_id) then
        return scaled("id:" .. entry.book_id, self, function()
            local ok, bb = pcall(function()
                return RenderImage:renderImageFile(self:coverFile(entry.book_id),
                                                   false, width, height)
            end)
            if not ok or not bb then return nil end
            return roundCorners(bb, math.floor(width * 0.045))
        end, width, height)
    end

    return nil
end

function CoverCache:clear()
    for _, bb in pairs(self.cache) do
        if bb and bb.free then bb:free() end
    end
    self.cache, self.misses = {}, {}
end

--- Number of covers held on disk.
function CoverCache:storedCount()
    local n = 0
    for name in lfs.dir(cacheDir()) do
        if name:match("%.jpg$") then n = n + 1 end
    end
    return n
end

return CoverCache
