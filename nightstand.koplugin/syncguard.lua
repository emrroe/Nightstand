--[[--
Keeps a reading position from being lost between devices.

Two ways it used to happen. A book downloaded from CWA opened on page one:
CWA writes its own id into every EPUB it serves, so a fresh copy has a
different checksum from one fetched elsewhere and the sync plugin found no
position for it. `seed` puts the download where the book was left before it
opens. And the sync plugin pushes whatever this device has, so that first
page then replaced the real position on the server; `attach` makes it ask
before a push would move another device's position backwards.
--]]--

local UIManager = require("ui/uimanager")
local Progress = require("progress")
local _ = require("gettext")
local T = require("ffi/util").template

local SyncGuard = {}

--- Write `record`'s position into `file`'s settings, so the reader opens
--- there. Without `force`, a book that already has a position keeps it.
function SyncGuard.seed(file, record, force)
    local position = record and record.progress
    if type(position) ~= "string" then return false end
    local DocSettings = require("docsettings")
    local settings = DocSettings:open(file)
    if not force and (settings:readSetting("last_xpointer") or settings:readSetting("last_page")) then
        return false
    end
    if position:match("^/body") then
        settings:saveSetting("last_xpointer", position)
    elseif tonumber(position) then
        settings:saveSetting("last_page", tonumber(position))
    else
        return false
    end
    settings:saveSetting("percent_finished", record.percentage)
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

--- Wrap the reader's sync plugin (CWA's or KOReader's own) so it checks the
--- server before its first push for a book, and asks rather than overwrite
--- a position another device has taken further.
function SyncGuard.attach(ui)
    local sync = ui and (ui.cwasync or ui.kosync)
    if not sync or sync.nightstand_guarded or type(sync.updateProgress) ~= "function" then return end
    sync.nightstand_guarded = true
    require("logger").info("Nightstand: guarding", sync.name or "sync", "pushes")
    local push = sync.updateProgress
    local cleared = false

    sync.updateProgress = function(self, ensure_networking, interactive, on_suspend)
        if cleared or interactive then return push(self, ensure_networking, interactive, on_suspend) end
        local NetworkMgr = require("ui/network/manager")
        if not NetworkMgr:isOnline() then
            -- offline the plugin defers itself and comes back through here
            return push(self, ensure_networking, interactive, on_suspend)
        end
        local digest = self:getDocumentDigest()
        local remote = digest and Progress:fetch(digest)
        local here = self:getLastPercent() or 0
        if not remote or remote.device_id == self.device_id or remote.percentage <= here + 0.01 then
            cleared = true
            return push(self, ensure_networking, interactive, on_suspend)
        end
        -- going to sleep is no moment for a question; the next push asks
        if on_suspend or self.nightstand_asking then return end
        self.nightstand_asking = true
        local device = remote.device or _("Another device")
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = T(_("%1 is further on in this book (%2%). This device is at %3%.\n\nGo to where %1 is, or keep reading here and save this position instead?"),
                     device, math.floor(remote.percentage * 100 + 0.5), math.floor(here * 100 + 0.5)),
            ok_text = _("Go there"),
            cancel_text = _("Keep this one"),
            ok_callback = function()
                self.nightstand_asking, cleared = false, true
                if remote.progress then self:syncToProgress(remote.progress) end
            end,
            cancel_callback = function()
                self.nightstand_asking, cleared = false, true
                push(self, ensure_networking, true, false)
            end,
        })
    end
end

return SyncGuard
