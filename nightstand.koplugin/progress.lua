--[[--
Reading positions, read back from the sync server.

A position is keyed by KOReader's partial MD5 of the file, so the same book
read on the Nova 2 and held here is one document. There is no bulk endpoint --
`/kosync/syncs/progress/all` is just a document id that does not exist -- so
this is one request per book and belongs in an explicit refresh.
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local Progress = { records = nil }

local function storePath()
    return DataStorage:getSettingsDir() .. "/nightstand_progress.lua"
end

function Progress:load()
    if self.records then
        self.history = self.history or {}
        return self.records
    end
    local store = LuaSettings:open(storePath())
    self.records = store:readSetting("records") or {}
    self.history = store:readSetting("history") or {}
    return self.records
end

function Progress:save()
    local store = LuaSettings:open(storePath())
    store:saveSetting("records", self.records or {})
    store:saveSetting("history", self.history or {})
    store:flush()
end

function Progress:get(checksum)
    if not checksum then return nil end
    return self:load()[checksum]
end

-- positions remembered per book, so one overwritten by mistake can be put back
local HISTORY = 8

--- Keep `record` as the latest for `key`, and in that key's history when it
--- is a new position.
function Progress:remember(key, record)
    self:load()[key] = record
    local list = self.history[key] or {}
    local last = list[1]
    if not last or last.device ~= record.device
       or math.abs((last.percentage or 0) - (record.percentage or 0)) > 0.001 then
        table.insert(list, 1, record)
        while #list > HISTORY do table.remove(list) end
    end
    self.history[key] = list
end

--- Every position remembered for a book, newest first, one per place reached.
function Progress:positions(entry)
    self:load()
    local out, seen = {}, {}
    for _index, key in pairs({ entry.checksum or false, Progress.bookKey(entry.book_id) or false }) do
        for _index2, record in ipairs(key and self.history[key] or {}) do
            local id = string.format("%s|%.3f", tostring(record.device), record.percentage or 0)
            if not seen[id] then
                seen[id] = true
                table.insert(out, record)
            end
        end
    end
    table.sort(out, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
    return out
end

--- A position the reader picked to restore for a book not on the device;
--- the download opens there. `choose(id, nil)` forgets it.
function Progress:chosen(book_id)
    return book_id and self:load()["chosen:" .. tostring(book_id)]
end

function Progress:choose(book_id, record)
    if not book_id then return end
    self:load()["chosen:" .. tostring(book_id)] = record
    self:save()
end

--- Ask the sync server where this document was left off.
function Progress:fetch(document)
    return (require("syncserver").get(document))
end

--- Tell the sync server where `document` (a checksum) is, as this device.
function Progress:push(document, record)
    return require("syncserver").put(document, record)
end

--- The key a server-only book's position is kept under. CWA 4.0.7 and later
--- store positions against the Calibre book id, so a book never downloaded
--- here can still say how far it was read elsewhere.
function Progress.bookKey(book_id)
    return book_id and ("book:" .. tostring(book_id))
end

--- Ask the server about one book, by checksum and by id. Does not save.
function Progress:refreshEntry(entry)
    self:load()
    local by_checksum = entry.checksum and self:fetch(entry.checksum)
    if by_checksum then self:remember(entry.checksum, by_checksum) end
    -- only CWA also answers by its own book id
    local by_id = entry.book_id and require("syncserver").current().kind == "cwa"
                  and self:fetch(tostring(entry.book_id))
    if by_id then self:remember(Progress.bookKey(entry.book_id), by_id) end
    return by_checksum ~= nil or by_id ~= nil
end

--- Refresh every book (or those `wanted` picks): held-locally ones by their
--- checksum, catalogue ones by their id. Returns how many have a position.
function Progress:refreshAll(entries, wanted)
    local found = 0
    for _index, entry in ipairs(entries) do
        if (not wanted or wanted(entry)) and self:refreshEntry(entry) then
            found = found + 1
        end
    end
    self:save()
    logger.info("Nightstand: positions known for", found, "books")
    return found
end

return Progress
