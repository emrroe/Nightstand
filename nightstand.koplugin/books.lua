--[[--
The shelf, as the home screen needs it.

For now every entry comes from the local folder. When the catalogue lands,
server-only books join the same list with `on_device = false`.
--]]--

local BookList = require("ui/widget/booklist")
local DocSettings = require("docsettings")
local Availability = require("availability")
local Catalog = require("catalog")
local Progress = require("progress")
local ReadHistory = require("readhistory")

local Books = {}

-- Copied verbatim from the catalogue onto the merged entry.
local CATALOGUE_FIELDS = {
    "book_id", "cover_url", "summary", "published", "language", "genres",
    "size", "added_rank", "series", "series_index",
}

local function baseName(path)
    local name = path:match("([^/]+)$") or path
    return (name:gsub("%.%w+$", ""))
end

--- Title and author, without opening the document.
local function propsFor(file)
    if not DocSettings:hasSidecarFile(file) then return nil end
    local ok, props = pcall(function()
        return DocSettings:open(file):readSetting("doc_props")
    end)
    return ok and props or nil
end

function Books:entryFor(file, checksum)
    local info = BookList.getBookInfo(file)
    local props = propsFor(file)
    local title = props and (props.display_title or props.title)
    if not title or title == "" then title = baseName(file) end
    local entry = {
        file = file,
        checksum = checksum,
        title = title,
        author = props and props.authors or "",
        pages = info and info.pages,
        percent = info and info.percent_finished,
        status = BookList.getBookStatus(file),
        on_device = true,
    }

    self:applyPosition(entry, Progress:get(checksum))
    return entry
end

--- A position read on another device only exists on the server. Take
--- whichever is further along rather than letting one overwrite the other.
function Books:applyPosition(entry, synced)
    if not synced or not synced.percentage then return end
    local at = tonumber(synced.timestamp)
    if at and at > (entry.server_read_at or 0) then entry.server_read_at = at end
    if synced.percentage > (entry.percent or 0) then
        entry.percent = synced.percentage
        entry.device = synced.device
        entry.synced_at = synced.timestamp
        entry.status = synced.percentage >= 1 and "complete" or "reading"
    end
end

--- Titles compared loosely: local names carry the author, catalogue ones
--- do not, so a containment test beats equality.
local function norm(str)
    str = (str or ""):lower():gsub("&#39;", "'")
    str = str:gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return str
end

--- Local files merged with the CWA catalogue. Books only on the server join
--- the list with `on_device = false` and carry their download link.
function Books:list(books_dir)
    local map = Availability:ensure(books_dir) or {}
    local entries, locals = {}, {}
    for checksum, file in pairs(map) do
        local entry = self:entryFor(file, checksum)
        table.insert(entries, entry)
        table.insert(locals, { key = norm(entry.title), entry = entry })
    end

    for _, item in ipairs(Catalog:load() or {}) do
        local key = norm(item.title)
        local matched
        for _, candidate in ipairs(locals) do
            if not candidate.taken
               and (candidate.key == key or candidate.key:find(key, 1, true)) then
                candidate.taken = true
                matched = candidate.entry
                break
            end
        end
        local entry = matched
        if matched then
            matched.title = item.title  -- the catalogue name beats the filename
            if matched.author == "" then matched.author = item.author end
        else
            entry = {
                title = item.title,
                author = item.author,
                download_url = item.download_url,
                status = "new",
                on_device = false,
            }
            table.insert(entries, entry)
        end
        for _, key in ipairs(CATALOGUE_FIELDS) do entry[key] = item[key] end
        entry.added = item.updated
        if item.read_on_server and entry.status ~= "reading" then
            entry.status = "complete"
        end
    end

    for _, entry in ipairs(entries) do
        self:applyPosition(entry, Progress:get(Progress.bookKey(entry.book_id)))
    end

    local last_read = {}
    for _, item in ipairs(ReadHistory.hist or {}) do
        last_read[item.file] = math.max(last_read[item.file] or 0, item.time or 0)
    end
    for _, entry in ipairs(entries) do
        local here = entry.file and last_read[entry.file] or 0
        local there = entry.server_read_at or 0
        if here > 0 or there > 0 then entry.last_read = math.max(here, there) end
    end

    table.sort(entries, function(a, b)
        local ap = a.status == "reading" and 0 or 1
        local bp = b.status == "reading" and 0 or 1
        if ap ~= bp then return ap < bp end
        return a.title < b.title
    end)
    return entries
end

--- The book the hero card shows, plus whether it is a suggestion rather
--- than something already under way.
function Books:current(entries)
    -- the book in progress you touched last, wherever you touched it
    local best
    for _, entry in ipairs(entries) do
        if entry.status == "reading" and entry.percent then
            local at, best_at = entry.last_read or 0, best and best.last_read or 0
            if not best or at > best_at or (at == best_at and entry.percent > best.percent) then
                best = entry
            end
        end
    end
    if best then return best, false end
    return entries[1], true
end

--- `New`, `42%` or `Finished` — the tag in the cover's top-right corner.
function Books:progressTag(entry)
    if entry.status == "complete" then return "Finished" end
    if entry.status == "new" or not entry.percent then return "New" end
    return string.format("%d%%", math.floor(entry.percent * 100 + 0.5))
end

--- Shelves for the stacked home layout. Only non-empty ones are drawn, so a
--- quiet library does not leave a labelled gap on screen.
function Books:shelves(entries, skip)
    local function pick(test, sort)
        local out = {}
        for _, entry in ipairs(entries) do
            if entry ~= skip and test(entry) then table.insert(out, entry) end
        end
        if sort then table.sort(out, sort) end
        return out
    end
    local by_added = function(a, b) return (a.added or "") > (b.added or "") end

    local by_read = function(a, b) return (a.last_read or 0) > (b.last_read or 0) end

    return {
        { label = "Reading now",
          books = pick(function(e) return e.status == "reading" end, by_read) },
        { label = "Next in series", books = self:nextInSeries(entries, skip) },
        { label = "Recently added",
          books = pick(function(e) return e.added ~= nil end, by_added) },
        { label = "On this device",
          books = pick(function(e) return e.on_device end, by_added) },
        { label = "Not read yet",
          books = pick(function(e) return e.status == "new" end, by_added) },
        { label = "Finished",
          books = pick(function(e) return e.status == "complete" end, by_read) },
    }
end

--- For every series you have started, the first book after the furthest one
--- you finished or are reading that you have not touched yet. Series you read
--- most recently come first.
function Books:nextInSeries(entries, skip)
    local series = {}
    for _, e in ipairs(entries) do
        if e.series and e.series_index then
            local s = series[e.series]
            if not s then
                s = { books = {}, reached = nil, activity = 0 }
                series[e.series] = s
            end
            table.insert(s.books, e)
            if e.status == "complete" or e.status == "reading" then
                s.reached = math.max(s.reached or -math.huge, e.series_index)
                s.activity = math.max(s.activity, e.last_read or 0)
            end
        end
    end
    local out = {}
    for _, s in pairs(series) do
        if s.reached then
            local next_book
            for _, e in ipairs(s.books) do
                if e.series_index > s.reached and e.status ~= "complete" and e.status ~= "reading"
                   and (not next_book or e.series_index < next_book.series_index) then
                    next_book = e
                end
            end
            if next_book and next_book ~= skip then
                table.insert(out, { book = next_book, activity = s.activity })
            end
        end
    end
    table.sort(out, function(a, b)
        if a.activity ~= b.activity then return a.activity > b.activity end
        return a.book.title < b.book.title
    end)
    for i, item in ipairs(out) do out[i] = item.book end
    return out
end

return Books
