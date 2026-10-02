--[[--
Reading positions, read back from CWA's KOSync endpoint.

A position is keyed by KOReader's partial MD5 of the file, so the same book
read on the Nova 2 and held here is one document. There is no bulk endpoint --
`/kosync/syncs/progress/all` is just a document id that does not exist -- so
this is one request per book and belongs in an explicit refresh.
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Catalog = require("catalog")
local rapidjson = require("rapidjson")
local logger = require("logger")

local Progress = { records = nil }

local function storePath()
    return DataStorage:getSettingsDir() .. "/nightstand_progress.lua"
end

function Progress:load()
    if self.records then return self.records end
    local store = LuaSettings:open(storePath())
    self.records = store:readSetting("records") or {}
    return self.records
end

function Progress:save()
    local store = LuaSettings:open(storePath())
    store:saveSetting("records", self.records or {})
    store:flush()
end

function Progress:get(checksum)
    if not checksum then return nil end
    return self:load()[checksum]
end

--- Ask the server where this document was left off.
function Progress:fetch(checksum)
    local body = Catalog:get("/kosync/syncs/progress/" .. checksum)
    if not body then return nil end
    local ok, data = pcall(rapidjson.decode, body)
    if not ok or type(data) ~= "table" or not data.percentage then return nil end
    return {
        percentage = data.percentage,
        device = data.device,
        timestamp = data.timestamp,
        title = data.calibre_book_title,
    }
end

--- The key a server-only book's position is kept under. CWA 4.0.7 and later
--- store positions against the Calibre book id, so a book never downloaded
--- here can still say how far it was read elsewhere.
function Progress.bookKey(book_id)
    return book_id and ("book:" .. tostring(book_id))
end

--- Refresh every book: held-locally ones by their checksum, and every
--- catalogue book by its id. Returns how many came back with a position.
function Progress:refreshAll(entries)
    local records = self:load()
    local found = 0
    for _, entry in ipairs(entries) do
        local by_checksum = entry.checksum and self:fetch(entry.checksum)
        if by_checksum then
            records[entry.checksum] = by_checksum
        end
        local by_id = entry.book_id and self:fetch(tostring(entry.book_id))
        if by_id then
            records[Progress.bookKey(entry.book_id)] = by_id
        end
        if by_checksum or by_id then found = found + 1 end
    end
    self.records = records
    self:save()
    logger.info("Nightstand: positions known for", found, "books")
    return found
end

return Progress
