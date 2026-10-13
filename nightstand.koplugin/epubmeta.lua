--[[--
What an EPUB says about itself -- title, authors, series and number,
description, date and language -- read from its package file without
rendering the book, for libraries that have no server to ask.

Results are kept per file (path, size and modification time), so a folder
is only read in full the first time.
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local EpubMeta = {}

local function storePath()
    return DataStorage:getSettingsDir() .. "/nightstand_local.lua"
end

local function decode(str)
    str = require("text").decode((str:gsub("<!%[CDATA%[(.-)%]%]>", "%1")))
    return (str:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function plain(html)
    local text = decode(html):gsub("<[^>]+>", " "):gsub("%s+", " ")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Parse an OPF package document into the fields Nightstand uses.
function EpubMeta.parse(opf)
    local function first(tag)
        local value = opf:match("<dc:" .. tag .. "[^>]*>(.-)</dc:" .. tag .. ">")
        return value and decode(value) or nil
    end
    local authors = {}
    for value in opf:gmatch("<dc:creator[^>]*>(.-)</dc:creator>") do
        table.insert(authors, decode(value))
    end
    local function meta(name)
        return opf:match('<meta[^>]-name="' .. name .. '"[^>]-content="([^"]*)"')
            or opf:match('<meta[^>]-content="([^"]*)"[^>]-name="' .. name .. '"')
    end
    -- calibre's series, or EPUB 3's collection with its position
    local series, index = meta("calibre:series"), meta("calibre:series_index")
    if not series then
        local id, name = opf:match('<meta[^>]-property="belongs%-to%-collection"[^>]-id="([^"]+)"[^>]*>(.-)</meta>')
        if id then
            series = name
            index = opf:match('<meta[^>]-refines="#' .. id .. '"[^>]-property="group%-position"[^>]*>(.-)</meta>')
        end
    end
    local description = first("description")
    return {
        title = first("title"),
        author = #authors > 0 and table.concat(authors, ", ") or nil,
        series = series and decode(series) or nil,
        series_index = tonumber(index),
        summary = description and plain(description) or nil,
        published = first("date"),
        language = first("language"),
    }
end

--- The package document's text, found through META-INF/container.xml.
function EpubMeta.packageOf(file)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(file) then return nil end
    -- the reader only finds an entry by name once it has listed them
    for _entry in reader:iterate() do end
    local container = reader:extractToMemory("META-INF/container.xml")
    local path = container and container:match('full%-path="([^"]+)"')
    local opf = path and reader:extractToMemory(path)
    reader:close()
    return opf
end

--- Metadata for `file`, from the cache when the file has not changed.
function EpubMeta.read(file)
    if not file:lower():match("%.epub$") then return nil end
    local attr = lfs.attributes(file)
    if not attr then return nil end
    local stamp = string.format("%d:%d", attr.size or 0, attr.modification or 0)
    EpubMeta.store = EpubMeta.store or LuaSettings:open(storePath())
    local cached = EpubMeta.store:readSetting(file)
    if cached and cached.stamp == stamp then return cached.meta end
    local ok, opf = pcall(EpubMeta.packageOf, file)
    local meta = ok and opf and EpubMeta.parse(opf) or {}
    EpubMeta.store:saveSetting(file, { stamp = stamp, meta = meta })
    EpubMeta.dirty = true
    return meta
end

--- Write the cache out after a folder has been read. With `present` (path ->
--- true, the whole folder), files no longer there are forgotten.
function EpubMeta.flush(present)
    if present and EpubMeta.store then
        for file in pairs(EpubMeta.store.data) do
            if not present[file] then
                EpubMeta.store:delSetting(file)
                EpubMeta.dirty = true
            end
        end
    end
    if EpubMeta.dirty and EpubMeta.store then
        EpubMeta.store:flush()
        EpubMeta.dirty = false
    end
end

return EpubMeta
