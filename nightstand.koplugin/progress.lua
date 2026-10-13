--[[--
Reading positions known from the sync server, and writing one into a book.

Positions are kept per document -- KOReader's partial MD5 of the file, or
the CWA book id for books not on this device -- with a short history of
each, so a position overwritten by mistake can be put back. The server
answers one document per request, so refreshing is background work.

A book opens where it was last read on any device rather than where this
device left it: for fresh downloads (CWA writes its own id into every EPUB
it serves, so a fresh copy can have a checksum no position is stored under)
and for books opened from Home while another device's position is newer.
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Progress = {
    records = nil,
    version = 0,  -- bumped whenever a position is learnt or written
    SAME_PLACE = 0.002,  -- positions closer than this count as one
}

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
    self.version = self.version + 1
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
    self.version = self.version + 1
    self:load()["chosen:" .. tostring(book_id)] = record
    self:save()
end

--- Ask the sync server where this document was left off.
function Progress:fetch(document)
    return (require("syncserver").get(document))
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

--- Write `record`'s position into `file`'s settings, so the reader opens
--- there. Without `force`, a book that already has a position keeps it.
--- Positions saved up to `answered` (default: the record's own time) count
--- as answered, so the sync does not ask about them on opening.
function Progress:seed(file, record, force, answered)
    local position = record and record.progress
    if type(position) ~= "string" then return false end
    local DocSettings = require("docsettings")
    local settings = DocSettings:open(file)
    if not force and (settings:readSetting("last_xpointer") or settings:readSetting("last_page")) then
        return false
    end
    if position:match("^/body") then
        settings:saveSetting("last_xpointer", position)
        -- a position with no renderer version reads as one from an old
        -- KOReader, which then offers to migrate a book it never opened
        if not settings:readSetting("cre_dom_version") then
            local cre = require("document/credocument"):engineInit()
            settings:saveSetting("cre_dom_version", cre.getLatestDomVersion())
        end
    elseif tonumber(position) then
        settings:saveSetting("last_page", tonumber(position))
    else
        return false
    end
    self.version = self.version + 1
    settings:saveSetting("percent_finished", record.percentage)
    settings:saveSetting("nightstand_synced", record.percentage)
    -- the book now opens at this position: the sync has nothing to ask about it
    answered = answered or record.timestamp
    if answered then settings:saveSetting("nightstand_sync_seen", answered) end
    settings:flush()
    return true
end

--- Whether `file` was read on this device past what the server knows of it:
--- a position no save or answer has reached the server with yet.
function Progress.unsynced(file)
    local settings = require("docsettings"):open(file)
    local here = settings:readSetting("percent_finished")
    if not here then return false end
    local synced = settings:readSetting("nightstand_synced")
    return not synced or math.abs(here - synced) >= Progress.SAME_PLACE
end

local function newer(a, b)
    if not a then return b end
    if not b then return a end
    return (b.timestamp or 0) > (a.timestamp or 0) and b or a
end

--- After downloading `entry` to `file`: the latest position the server has
--- for it, by the new copy's checksum or by book id -- or one the reader
--- picked to restore -- written into the copy.
function Progress:seedDownload(entry, file)
    local ok, checksum = pcall(require("util").partialMD5, file)
    local record = self:chosen(entry.book_id)
    if not record then
        local by_checksum = ok and checksum and self:fetch(checksum)
        local by_id = entry.book_id and self:fetch(tostring(entry.book_id))
        if by_checksum then self:remember(checksum, by_checksum) end
        if by_id then self:remember(Progress.bookKey(entry.book_id), by_id) end
        self:save()
        record = newer(by_checksum, by_id)
    end
    self:choose(entry.book_id, nil)
    return self:seed(file, record)
end

return Progress
