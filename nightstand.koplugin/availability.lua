--[[--
Which books are already on this device.

The key is KOReader's own partial MD5, which is also the checksum CWA stores
against each format, so a match is proof rather than a filename guess.
--]]--

local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")

local Availability = {
    map = nil,   -- checksum -> absolute path
    root = nil,
}

local BOOK_EXT = {
    epub = true, pdf = true, mobi = true, azw3 = true,
    fb2 = true, cbz = true, djvu = true, txt = true,
}

local function extension(name)
    return (name:match("%.([%a%d]+)$") or ""):lower()
end

function Availability:scan(root)
    local map = {}
    local count = 0

    local function walk(dir)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr then
                    if attr.mode == "directory" then
                        walk(path)
                    elseif attr.mode == "file" and BOOK_EXT[extension(name)] then
                        local sum = util.partialMD5(path)
                        if sum then
                            map[sum] = path
                            count = count + 1
                        end
                    end
                end
            end
        end
    end

    if root and lfs.attributes(root, "mode") == "directory" then
        walk(root)
    end

    self.root, self.map = root, map
    logger.info("Nightstand: indexed", count, "books under", tostring(root))
    return map
end

function Availability:ensure(root)
    if self.map == nil or self.root ~= root then
        self:scan(root)
    end
    return self.map
end

--- Absolute path for a checksum, or nil when the book is server-only.
function Availability:pathFor(checksum)
    return self.map and self.map[checksum] or nil
end

function Availability:isLocal(checksum)
    return self:pathFor(checksum) ~= nil
end

function Availability:count()
    if not self.map then return 0 end
    local n = 0
    for _ in pairs(self.map) do n = n + 1 end
    return n
end

--- Called after a download or a delete, so the next lookup is correct
--- without paying for a full rescan.
function Availability:add(checksum, path)
    if self.map and checksum then self.map[checksum] = path end
end

function Availability:remove(checksum)
    if self.map and checksum then self.map[checksum] = nil end
end

function Availability:invalidate()
    self.map, self.root = nil, nil
end

return Availability
