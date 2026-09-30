--[[--
Cover thumbnails, scaled once and kept at the size the grid asks for.

Extracting a cover means opening the document, so a miss is expensive and a
book without one must only be tried once.
--]]--

local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local RenderImage = require("ui/renderimage")

local CoverCache = {
    cache = {},   -- "file|WxH" -> BlitBuffer
    misses = {},  -- file -> true, for books with no extractable cover
}

function CoverCache:get(file, width, height)
    if not file or not width or not height then return nil end
    width, height = math.floor(width), math.floor(height)
    local key = string.format("%s|%dx%d", file, width, height)
    if self.cache[key] then return self.cache[key] end
    if self.misses[file] then return nil end

    local ok, bb = pcall(BookInfo.getCoverImage, BookInfo, nil, file)
    if not ok or not bb then
        self.misses[file] = true
        return nil
    end
    local scaled = RenderImage:scaleBlitBuffer(bb, width, height, true)
    self.cache[key] = scaled
    return scaled
end

function CoverCache:clear()
    for _, bb in pairs(self.cache) do
        if bb and bb.free then bb:free() end
    end
    self.cache, self.misses = {}, {}
end

return CoverCache
