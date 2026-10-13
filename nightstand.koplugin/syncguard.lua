--[[--
Opens a book where it was last read, on any device, rather than where this
device left it -- for fresh downloads, and for books opened from Home or
the Library while another device's position is the most recent.

CWA writes its own id into every EPUB it serves, so a fresh copy can have a
different checksum from one fetched elsewhere and find no position under it.
`seedDownload` writes the latest known position -- by checksum or by CWA
book id -- into the new copy's settings before it opens.
--]]--

local Progress = require("progress")

local SyncGuard = {}

--- Write `record`'s position into `file`'s settings, so the reader opens
--- there. Without `force`, a book that already has a position keeps it.
--- Positions saved up to `answered` (default: the record's own time) count
--- as answered, so the sync does not ask about them on opening.
function SyncGuard.seed(file, record, force, answered)
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
    settings:saveSetting("percent_finished", record.percentage)
    -- the book now opens at this position: the sync has nothing to ask about it
    answered = answered or record.timestamp
    if answered then settings:saveSetting("nightstand_sync_seen", answered) end
    settings:flush()
    return true
end

local function newer(a, b)
    if not a then return b end
    if not b then return a end
    return (b.timestamp or 0) > (a.timestamp or 0) and b or a
end

--- After downloading `entry` to `file`: the latest position the server has
--- for it, by the new copy's checksum or by book id -- or one the reader
--- picked to restore -- written into the copy.
function SyncGuard.seedDownload(entry, file)
    local ok, checksum = pcall(require("util").partialMD5, file)
    local record = Progress:chosen(entry.book_id)
    if not record then
        local by_checksum = ok and checksum and Progress:fetch(checksum)
        local by_id = entry.book_id and Progress:fetch(tostring(entry.book_id))
        if by_checksum then Progress:remember(checksum, by_checksum) end
        if by_id then Progress:remember(Progress.bookKey(entry.book_id), by_id) end
        Progress:save()
        record = newer(by_checksum, by_id)
    end
    Progress:choose(entry.book_id, nil)
    return SyncGuard.seed(file, record)
end

return SyncGuard
