--[[--
Fetching a book off the server and onto the device.

Downloads mirror the folder layout already on disk -- one folder per author,
"<title> - <author>.epub" inside it -- so a fetched book is indistinguishable
from one that was copied across by hand.
--]]--

local Availability = require("availability")
local Catalog = require("catalog")
local Settings = require("settings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")

local Download = {}

local function sanitise(name)
    name = (name or ""):gsub('[/\\%?%*:|"<>]', " ")
    return (name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Download:destinationFor(entry)
    local books = Settings:booksDir()
    -- Calibre joins co-authors with a comma; the folder takes the first.
    local author = sanitise((entry.author or ""):match("^[^,]+") or "")
    if author == "" then author = "Unknown" end
    local title = sanitise(entry.title)
    if title == "" then title = "Untitled" end

    local dir = books .. "/" .. author
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return string.format("%s/%s - %s.epub", dir, title, author)
end

--- Returns ok, path-or-error. On success `entry` is updated in place so the
--- caller can open it without rebuilding the shelf.
function Download:book(entry)
    if not entry.download_url then return false, "this book has no download link" end
    if Settings:booksDir() == "" then return false, "no books folder is set" end

    local dest = self:destinationFor(entry)
    if lfs.attributes(dest, "mode") == "file" then
        logger.info("Nightstand: already on disk:", dest)
    else
        local ok, err = Catalog:fetchTo(entry.download_url, dest)
        if not ok then return false, err end
    end

    local checksum = util.partialMD5(dest)
    Availability:add(checksum, dest)
    entry.file, entry.checksum, entry.on_device = dest, checksum, true
    logger.info("Nightstand: downloaded", entry.title, "to", dest)
    return true, dest
end

return Download
