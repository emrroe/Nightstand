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
    -- the format is in CWA's link: /opds/download/<id>/<format>/
    local format = (entry.download_url or ""):match("/opds/download/%d+/(%w+)/?$") or "epub"
    return string.format("%s/%s - %s.%s", dir, title, author, format:lower())
end

local function inProcess(task) return true, task() end

--- Returns ok, path-or-error; ok is nil when the reader stopped it. On
--- success `entry` is updated in place so the caller can open it without
--- rebuilding the shelf. `run(task)` runs the transfer and returns whether
--- it completed, then the task's results (default: here, to the end).
function Download:book(entry, run)
    if not entry.download_url then return false, "this book has no download link" end
    if Settings:booksDir() == "" then return false, "no books folder is set" end

    local dest = self:destinationFor(entry)
    if lfs.attributes(dest, "mode") == "file" then
        logger.info("Nightstand: already on disk:", dest)
    else
        util.makePath((dest:match("^(.*)/")))
        local completed, ok, err = (run or inProcess)(function() return Catalog:fetchTo(entry.download_url, dest) end)
        if not completed then
            os.remove(dest .. ".part")
            return nil
        end
        if not ok then return false, err or "the transfer ended unexpectedly" end
    end

    local checksum = util.partialMD5(dest)
    Availability:add(checksum, dest)
    entry.file, entry.checksum, entry.on_device = dest, checksum, true
    logger.info("Nightstand: downloaded", entry.title, "to", dest)
    return true, dest
end

return Download
