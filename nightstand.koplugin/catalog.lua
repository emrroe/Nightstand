--[[--
The shelf as Calibre-Web-Automated sees it.

CWA's OPDS root is a navigation feed; `/opds/books/letter/00` is the flat
"All" acquisition feed, which is the only one worth fetching. The parsed
result is written to disk so the home screen paints without a round trip.
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")
local util = require("util")
local rapidjson = require("rapidjson")
local Settings = require("settings")

local ALL_BOOKS = "/opds/books/letter/00"

local Catalog = {
    entries = nil,
    fetched_at = nil,
}

local function storePath()
    return DataStorage:getSettingsDir() .. "/nightstand_catalog.lua"
end

local function credentials()
    local user = Settings:get("username") or ""
    local password = Settings:get("password") or ""
    if user ~= "" and password ~= "" then return user, password end
    -- Fall back to the CWA sync plugin's credentials rather than asking twice.
    local cwa = G_reader_settings and G_reader_settings:readSetting("cwasync")
    if cwa and cwa.username and cwa.password and cwa.password ~= "" then
        return cwa.username, cwa.password
    end
    if user == "" or password == "" then return nil, nil end
    return user, password
end

--- One HTTP GET against the configured server. Returns body or nil, err.
function Catalog:get(path)
    local server = Settings:get("server"):gsub("/+$", "")
    if server == "" then return nil, "no server configured" end
    local user, password = credentials()

    local sink = {}
    socketutil:set_timeout(10, 30)
    local code, _headers, status = socket.skip(1, http.request{
        url = server .. path,
        method = "GET",
        headers = { ["Accept-Encoding"] = "identity" },
        sink = ltn12.sink.table(sink),
        user = user,
        password = password,
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        return nil, tostring(status or code)
    end
    local body = table.concat(sink)
    return body ~= "" and body or nil, body == "" and "empty response" or nil
end

-- KOReader's OPDS parser keeps only the last of any repeated element except
-- entry/link, which loses every author after the first -- CWA lists the
-- translator as a second author, so that is the one that survives. The five
-- fields below are easier to read straight off the feed, and doing so drops
-- the dependency on the OPDS plugin being enabled.

local function decode(str)
    if not str then return "" end
    str = str:gsub("&#(%d+);", function(code)
        return util.unicodeCodepointToUtf8(tonumber(code))
    end)
    return (str:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
               :gsub("&apos;", "'"):gsub("&amp;", "&"))
end

local function linksIn(block)
    local links = {}
    for attrs in block:gmatch("<link([^>]*)>") do
        local rel = attrs:match('rel="([^"]*)"')
        local href = attrs:match('href="([^"]*)"')
        if rel and href then links[rel] = href end
    end
    return links
end

--- CWA puts the publisher blurb in <summary>, HTML and all.
local function summaryIn(block)
    local raw = block:match("<summary>(.-)</summary>")
    if not raw then return nil end
    local plain = decode(raw):gsub("&lt;.-&gt;", " "):gsub("<.->", " ")
    plain = plain:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if plain == "" then return nil end
    return plain
end

local function authorsIn(block)
    local names = {}
    for author in block:gmatch("<author>(.-)</author>") do
        local name = author:match("<name>(.-)</name>")
        if name then table.insert(names, decode(name)) end
    end
    return table.concat(names, ", ")
end

--- Stream a path from the server straight into a local file. Book files can
--- run to tens of megabytes, so this does not buffer the body the way get() does.
function Catalog:fetchTo(path, dest)
    local server = Settings:get("server"):gsub("/+$", "")
    if server == "" then return false, "no server configured" end
    local user, password = credentials()

    local handle, io_err = io.open(dest, "wb")
    if not handle then return false, io_err or "could not write the file" end

    socketutil:set_timeout(20, 300)
    local code, _headers, status = socket.skip(1, http.request{
        url = server .. path,
        method = "GET",
        headers = { ["Accept-Encoding"] = "identity" },
        sink = socketutil.file_sink(handle),
        user = user,
        password = password,
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        os.remove(dest)
        return false, tostring(status or code)
    end
    return true
end

--- Every <entry> block of a feed, following rel="next" -- CWA pages its
--- OPDS feeds (60 books by default), so one request only covers small libraries.
function Catalog:entryBlocks(path)
    local blocks, seen = {}, {}
    while path and not seen[path] do
        seen[path] = true
        local body, err = self:get(path)
        if not body then
            if #blocks == 0 then return nil, err end
            break
        end
        for block in body:gmatch("<entry>(.-)</entry>") do table.insert(blocks, block) end
        path = nil
        for attrs in body:gmatch("<link([^>]*)>") do
            if attrs:match('rel="next"') then
                path = decode(attrs:match('href="([^"]*)"'))
                break
            end
        end
    end
    return blocks
end

--- The acquisition link to use, EPUB when the book has several formats,
--- and that file's size.
local function downloadIn(block)
    local first, first_size
    for attrs in block:gmatch("<link([^>]*)>") do
        if attrs:match('rel="http://opds%-spec.org/acquisition"') then
            local href = attrs:match('href="([^"]*)"')
            local size = tonumber(attrs:match('length="(%d+)"'))
            if href and attrs:match('type="application/epub%+zip"') then return href, size end
            if not first then first, first_size = href, size end
        end
    end
    return first, first_size
end

local function bookIdIn(block)
    local download = downloadIn(block)
    return download and tonumber(download:match("/opds/download/(%d+)/"))
end

-- BISAC catch-alls that every book carries; they only add noise as genres.
local NOT_A_GENRE = { General = true, Fiction = true }

local function genresIn(block)
    local genres = {}
    for label in block:gmatch('<category[^>]-label="([^"]*)"') do
        label = decode(label)
        if not NOT_A_GENRE[label] then table.insert(genres, label) end
    end
    return genres
end

--- Calibre ids in the order a feed lists them.
function Catalog:idsIn(path)
    local blocks = self:entryBlocks(path)
    if not blocks then return nil end
    local ids = {}
    for _, block in ipairs(blocks) do
        local id = bookIdIn(block)
        if id then table.insert(ids, id) end
    end
    return ids
end

--- Series name and position for each book. The book entries carry no series,
--- so this walks CWA's series feeds; each lists its books in series order.
function Catalog:seriesById()
    local out = {}
    local index = self:entryBlocks("/opds/series/letter/00")
    for _, block in ipairs(index or {}) do
        local name = decode(block:match("<title>(.-)</title>"))
        local href
        for attrs in block:gmatch("<link([^>]*)>") do
            href = attrs:match('href="(/opds/series/%d+[^"]*)"') or href
        end
        if href then
            for position, id in ipairs(self:idsIn(decode(href)) or {}) do
                out[id] = { name = name, index = position }
            end
        end
    end
    return out
end

--- The real position in the series ("book 3"), which OPDS leaves out. CWA's
--- book JSON has it, keyed by uuid; an unchanged book keeps the last answer.
function Catalog:seriesIndex(entry, previous)
    if previous and previous.updated == entry.updated and previous.series_index_known then
        entry.series_index_known = true
        return previous.series_index
    end
    if not entry.uuid then return nil end
    local body = self:get("/ajax/book/" .. entry.uuid)
    local ok, data = pcall(rapidjson.decode, body or "")
    if ok and type(data) == "table" and tonumber(data.series_index) then
        entry.series_index_known = true
        return tonumber(data.series_index)
    end
end

--- Pull the flat book feed and keep the fields the home and library need.
function Catalog:refresh()
    local blocks, err = self:entryBlocks(ALL_BOOKS)
    if not blocks then
        logger.warn("Nightstand: catalogue fetch failed:", tostring(err))
        return nil, err
    end

    local entries = {}
    for _, block in ipairs(blocks) do
        local links = linksIn(block)
        local download, size = downloadIn(block)
        if download then
            table.insert(entries, {
                title = decode(block:match("<title>(.-)</title>")),
                summary = summaryIn(block),
                author = authorsIn(block),
                updated = block:match("<updated>(.-)</updated>"),
                published = block:match("<published>(.-)</published>"),
                language = block:match("<dcterms:language>(.-)</dcterms:language>"),
                genres = genresIn(block),
                size = size,
                cover_url = links["http://opds-spec.org/image"],
                download_url = download,
                -- /opds/download/<id>/epub/ -- the Calibre id is the useful part
                book_id = bookIdIn(block),
                uuid = block:match("<id>urn:uuid:([%x%-]+)</id>"),
            })
        end
    end
    if #entries == 0 then return nil, "the feed held no books" end

    -- The extras below are best effort: a missing one only costs a sort key.
    local added = self:idsIn("/opds/new")
    local series = self:seriesById()
    local read = {}
    for _, id in ipairs(self:idsIn("/opds/readbooks") or {}) do read[id] = true end
    local rank = {}
    for position, id in ipairs(added or {}) do rank[id] = position end
    local previous = {}
    for _, old in ipairs(self:load() or {}) do previous[old.book_id] = old end
    for _, entry in ipairs(entries) do
        entry.added_rank = rank[entry.book_id]
        local s = series[entry.book_id]
        if s then
            entry.series = s.name
            entry.series_index = self:seriesIndex(entry, previous[entry.book_id]) or s.index
        end
        entry.read_on_server = read[entry.book_id] or nil
    end

    self.entries = entries
    self.fetched_at = os.time()
    self:save()
    logger.info("Nightstand: catalogue holds", #entries, "books")
    return entries
end

function Catalog:save()
    local store = LuaSettings:open(storePath())
    store:saveSetting("entries", self.entries)
    store:saveSetting("fetched_at", self.fetched_at)
    store:flush()
end

function Catalog:load()
    if self.entries then return self.entries end
    local store = LuaSettings:open(storePath())
    self.entries = store:readSetting("entries")
    self.fetched_at = store:readSetting("fetched_at")
    return self.entries
end

function Catalog:count()
    local entries = self:load()
    return entries and #entries or 0
end

return Catalog
