--[[--
What the Discover tab shows, fetched from Hardcover and kept on disk.

Hardcover's own Discover page is built from "vibes": Top Picks and
Recommendations exist for every account, each a ranked list of book ids. Add
the reader's Want to read list and books similar to whatever they are
reading, look up the details of the ones that will be shown, and that is the
whole screen in about five requests.
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local Hardcover = require("hardcover")

local Discover = { data = nil }

-- statuses in a Hardcover library
Discover.WANT, Discover.READING, Discover.READ = 1, 2, 3

-- how many books per list get details and covers
local PER_LIST = 24

local function storePath()
    return DataStorage:getSettingsDir() .. "/nightstand_discover.lua"
end

--- rapidjson turns JSON null into a userdata sentinel; treat it as absent.
local function val(x)
    if type(x) == "userdata" then return nil end
    return x
end

function Discover:load()
    if self.data then return self.data end
    self.data = LuaSettings:open(storePath()):readSetting("data")
    return self.data
end

function Discover:save()
    local store = LuaSettings:open(storePath())
    store:saveSetting("data", self.data)
    store:flush()
end

function Discover:clear()
    self.data = nil
    os.remove(storePath())
end

local function authorsOf(contributors)
    local names = {}
    for _, c in ipairs(val(contributors) or {}) do
        local author = val(c.author)
        local role = val(c.contribution)
        if author and val(author.name) and (role == nil or role == "Author") then
            table.insert(names, author.name)
        end
    end
    return table.concat(names, ", ")
end

local function imageOf(image)
    image = val(image)
    if type(image) == "table" then return val(image.url) end
    return nil
end

--- One book from the API, flattened to what the screens need.
local function bookOf(raw)
    return {
        hc_id = raw.id,
        title = val(raw.title) or "",
        author = authorsOf(raw.cached_contributors),
        summary = val(raw.description),
        image_url = imageOf(raw.cached_image),
        year = val(raw.release_year),
        pages = val(raw.pages),
        rating = val(raw.rating),
    }
end

local BOOK_FIELDS = "id title cached_contributors cached_image release_year pages rating description"

--- Fetch everything. `current_title` is the book being read, for "More like".
--- Returns the data or nil, err; on failure the cached data stays.
function Discover:refresh(current_title)
    local account = require("settings"):get("hardcover")
    local uid = account and account.user_id
    if not uid then return nil, "not linked" end

    local mine, err = Hardcover:query(
        "query($u:Int!){ user_books(where:{user_id:{_eq:$u}}, limit:2000){ id book_id status_id } }",
        { u = uid })
    if not mine then return nil, err end
    local library, want = {}, {}
    for _, ub in ipairs(val(mine.user_books) or {}) do
        library[ub.book_id] = { id = ub.id, status = val(ub.status_id) }
        if val(ub.status_id) == Discover.WANT then table.insert(want, ub.book_id) end
    end

    local vibes = Hardcover:query(
        "query($u:Int!){ vibes(where:{user_id:{_eq:$u}, vibe_type:{_in:[1,3]}}){ vibe_type cached_book_ids } }",
        { u = uid })
    local lists = { want = want, top = {}, recs = {}, similar = {} }
    for _, vibe in ipairs(vibes and val(vibes.vibes) or {}) do
        local ids = val(vibe.cached_book_ids) or {}
        if vibe.vibe_type == 3 then lists.top = ids end
        if vibe.vibe_type == 1 then lists.recs = ids end
    end

    local similar_to
    if current_title and current_title ~= "" then
        local found = Hardcover:query(
            "query($t:String!){ books(where:{title:{_eq:$t}}, limit:1, order_by:{users_count:desc}){ id cached_similar_book_ids } }",
            { t = current_title })
        local book = found and val(found.books) and found.books[1]
        if book then
            lists.similar = val(book.cached_similar_book_ids) or {}
            similar_to = current_title
        end
    end

    -- Drop what the reader has already read or is reading, keep the order,
    -- and only look up the books that can actually be shown.
    local wanted, order = {}, {}
    local function trim(ids, keep_want)
        local out = {}
        for _, id in ipairs(ids) do
            local status = library[id] and library[id].status
            local seen_it = status == Discover.READ or status == Discover.READING
            if not seen_it and (keep_want or status ~= Discover.WANT) and #out < PER_LIST then
                table.insert(out, id)
                if not wanted[id] then wanted[id] = true; table.insert(order, id) end
            end
        end
        return out
    end
    lists.want = trim(lists.want, true)
    lists.top = trim(lists.top)
    lists.recs = trim(lists.recs)
    lists.similar = trim(lists.similar)

    local books = {}
    for start = 1, #order, 100 do
        local batch = {}
        for i = start, math.min(#order, start + 99) do table.insert(batch, order[i]) end
        local found = Hardcover:query(
            "query($ids:[Int!]){ books(where:{id:{_in:$ids}}){ " .. BOOK_FIELDS .. " } }",
            { ids = batch })
        for _, raw in ipairs(found and val(found.books) or {}) do
            books[raw.id] = bookOf(raw)
        end
    end

    self.data = {
        fetched_at = os.time(),
        lists = lists,
        books = books,
        library = library,
        similar_to = similar_to,
    }
    self:save()
    logger.info("Nightstand: Discover holds", #order, "books")
    return self.data
end

-- covers ------------------------------------------------------------------------

local function extensionOf(url)
    local ext = (url or ""):match("%.(%a+)$")
    ext = ext and ext:lower()
    if ext == "jpeg" or ext == "png" or ext == "webp" or ext == "gif" then return ext end
    return "jpg"
end

--- The renderer picks a decoder by extension, so the cover keeps its own.
function Discover:coverFile(hc_id, url)
    if not url then
        local data = self:load()
        local book = data and data.books[hc_id]
        url = book and book.image_url
    end
    return DataStorage:getDataDir() .. "/cache/nightstand/hc_" .. tostring(hc_id) .. "." .. extensionOf(url)
end

function Discover:hasCover(hc_id, url)
    return lfs.attributes(self:coverFile(hc_id, url), "mode") == "file"
end

--- Hardcover's images live on their own CDN, not on the CWA server.
function Discover:fetchCover(book)
    if not book.image_url then return false end
    if self:hasCover(book.hc_id, book.image_url) then return true end
    local dir = DataStorage:getDataDir() .. "/cache"
    lfs.mkdir(dir)
    lfs.mkdir(dir .. "/nightstand")
    local path = self:coverFile(book.hc_id, book.image_url)
    local handle = io.open(path, "wb")
    if not handle then return false end
    socketutil:set_timeout(10, 30)
    local code = socket.skip(1, http.request{
        url = book.image_url,
        method = "GET",
        headers = { ["User-Agent"] = "Nightstand (KOReader plugin)" },
        sink = socketutil.file_sink(handle),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        os.remove(path)
        return false
    end
    return true
end

function Discover:fetchCovers(limit)
    local data = self:load()
    if not data then return 0 end
    local fetched = 0
    for _, name in ipairs({ "top", "want", "recs", "similar" }) do
        for i, id in ipairs(data.lists[name] or {}) do
            if i > (limit or 12) then break end
            local book = data.books[id]
            if book and not self:hasCover(id, book.image_url) and self:fetchCover(book) then
                fetched = fetched + 1
            end
        end
    end
    return fetched
end

-- the reader's library -------------------------------------------------------------

function Discover:isWanted(hc_id)
    local data = self:load()
    local entry = data and data.library[hc_id]
    return entry ~= nil and entry.status == Discover.WANT
end

--- Add to or remove from Want to read. Returns ok, err.
function Discover:setWanted(hc_id, wanted)
    local data = self:load()
    if not data then return false, "nothing loaded" end
    local entry = data.library[hc_id]
    if wanted then
        local result, err
        if entry then
            result, err = Hardcover:query(
                "mutation($id:Int!){ update_user_book(id:$id, object:{status_id:1}){ id error } }",
                { id = entry.id })
            result = result and result.update_user_book
        else
            result, err = Hardcover:query(
                "mutation($b:Int!){ insert_user_book(object:{book_id:$b, status_id:1}){ id error } }",
                { b = hc_id })
            result = result and result.insert_user_book
        end
        if not result then return false, err end
        if val(result.error) then return false, result.error end
        data.library[hc_id] = { id = val(result.id) or (entry and entry.id), status = Discover.WANT }
        local present = false
        for _, id in ipairs(data.lists.want) do if id == hc_id then present = true end end
        if not present then table.insert(data.lists.want, 1, hc_id) end
    else
        if not entry then return true end
        local result, err = Hardcover:query(
            "mutation($id:Int!){ delete_user_book(id:$id){ id } }", { id = entry.id })
        if not result then return false, err end
        data.library[hc_id] = nil
        for i, id in ipairs(data.lists.want) do
            if id == hc_id then table.remove(data.lists.want, i) break end
        end
    end
    self:save()
    return true
end

-- matching against the CWA catalogue -----------------------------------------------

local function norm(str)
    str = (str or ""):lower():gsub("&#39;", "'")
    str = str:gsub("^the ", ""):gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return str
end

local function surname(author)
    local first = (author or ""):match("^[^,]+") or ""
    return (first:match("(%S+)%s*$") or ""):lower()
end

--- The catalogue entry for a Hardcover book, when the library already has it.
function Discover.match(book, entries)
    local title, who = norm(book.title), surname(book.author)
    for _, entry in ipairs(entries or {}) do
        if norm(entry.title) == title and (who == "" or surname(entry.author) == who) then
            return entry
        end
    end
    return nil
end

return Discover
