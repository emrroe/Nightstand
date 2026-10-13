--[[--
Shares the open book's position with the sync server, one rule first:
nothing is saved to the server until this device has compared its position
with the server's since the book opened (or the device woke).

A device that reads offline therefore never overwrites another device's
place by accident. As soon as it can reach the server -- on opening, when
the network comes back, or on a later page turn -- it compares; when another
device left the book somewhere else it asks which place to keep, whichever
direction that is. After that, saves follow reading: a short pause after the
last page turn, on closing the book and when the device goes to sleep.

One engine runs per open book; the plugin feeds it the reader's events.
--]]--

local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local SyncServer = require("syncserver")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local SyncEngine = {}
SyncEngine.__index = SyncEngine

local IDLE_SAVE = 10   -- seconds without a page turn before saving
local RETRY = 30       -- seconds between tries while the server cannot be reached
local SAME_PLACE = require("progress").SAME_PLACE

local function now() return os.time() end

function SyncEngine.new(ui, opts)
    opts = opts or {}
    local self = setmetatable({
        ui = ui,
        checked = false,   -- compared with the server since opening or waking
        dirty = false,     -- moved since the last save
        asking = false,
        last_try = -math.huge,
        online = opts.online or function() return NetworkMgr:isOnline() end,
        clock = opts.clock or now,
    }, SyncEngine)
    self.save_task = function() self:save() end
    self.check_task = function() self:check() end
    return self
end

function SyncEngine:document()
    if self.digest then return self.digest end
    local settings = self.ui.doc_settings
    self.digest = settings and settings:readSetting("partial_md5_checksum")
    if not self.digest and self.ui.document and self.ui.document.file then
        local ok, sum = pcall(require("util").partialMD5, self.ui.document.file)
        self.digest = ok and sum or nil
    end
    return self.digest
end

--- This device's position: `{ progress, percentage }`.
function SyncEngine:here()
    local Math = require("optmath")
    if self.ui.document.info.has_pages then
        return { progress = tostring(self.ui.paging:getLastProgress()),
                 percentage = Math.roundPercent(self.ui.paging:getLastPercent()) }
    end
    return { progress = self.ui.rolling:getLastProgress(),
             percentage = Math.roundPercent(self.ui.rolling:getLastPercent()) }
end

function SyncEngine:goTo(progress)
    if self.ui.document.info.has_pages then
        self.ui:handleEvent(Event:new("GotoPage", tonumber(progress)))
    else
        self.ui:handleEvent(Event:new("GotoXPointer", progress))
    end
end

local function deviceId()
    return G_reader_settings and G_reader_settings:readSetting("device_id")
end

--- A position from another device that this book has already answered for
--- (by going there or by keeping its own) is not asked about again.
function SyncEngine:seen(remote)
    local seen = self.ui.doc_settings and self.ui.doc_settings:readSetting("nightstand_sync_seen")
    return seen ~= nil and remote.timestamp ~= nil and remote.timestamp <= seen
end

--- The server knows this device's place as `percentage`: Home may then open
--- the book at a newer one from elsewhere without asking.
function SyncEngine:markSynced(percentage)
    if self.ui.doc_settings then self.ui.doc_settings:saveSetting("nightstand_synced", percentage) end
end

function SyncEngine:acknowledge(remote)
    if self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("nightstand_sync_seen", remote.timestamp or self.clock())
    end
end

--- Compare with the server, once it can be reached.
function SyncEngine:check()
    if self.checked or self.asking or not self:document() or not self.online() then return end
    self.last_try = self.clock()
    if not SyncServer.reachable() then return end
    local remote, err = SyncServer.get(self:document())
    if err then
        logger.info("Nightstand sync: server not reachable, will try again:", err)
        return
    end
    local here = self:here()
    if remote and (remote.progress == here.progress or math.abs(remote.percentage - here.percentage) < SAME_PLACE) then
        self:markSynced(here.percentage)
        return self:settle()
    end
    if not remote or (remote.device_id ~= nil and remote.device_id == deviceId()) or self:seen(remote) then
        return self:settle()
    end
    self:ask(remote, here)
end

function SyncEngine:settle()
    self.checked = true
    if self.dirty then self:save() end
end

local function when(timestamp)
    if not timestamp then return nil end
    local day = os.date("%Y%m%d", timestamp)
    if day == os.date("%Y%m%d") then return T(_("today %1"), os.date("%H:%M", timestamp)) end
    return os.date("%d %b %H:%M", timestamp)
end

function SyncEngine:ask(remote, here)
    self.asking = true
    local device = remote.device or _("Another device")
    local pct = function(p) return math.floor(p * 100 + 0.5) end
    local at = when(remote.timestamp)
    require("dialogs").confirm{
        title = T(_("%1 is somewhere else in this book"), device),
        text = T(_("%1 is at %2%%3. This device is at %4%. Go to where %1 is, or keep reading here?"),
                 device, pct(remote.percentage), at and (" (" .. at .. ")") or "", pct(here.percentage)),
        -- only an answer closes it: a stray tap must not decide
        dismissable = false,
        ok_text = T(_("Go to %1"), device),
        cancel_text = _("Keep this one"),
        ok_callback = function()
            self.asking = false
            self:acknowledge(remote)
            self.checked, self.dirty = true, false
            self:markSynced(remote.percentage)
            if remote.progress then self:goTo(remote.progress) end
        end,
        cancel_callback = function()
            self.asking = false
            self:acknowledge(remote)
            self.dirty = true
            self:settle()
        end,
    }
end

--- Save this device's position, if it has been compared and has moved.
function SyncEngine:save()
    UIManager:unschedule(self.save_task)
    if not (self.checked and self.dirty) or not self:document() or not self.online() then return end
    local here = self:here()
    local ok, err = SyncServer.put(self:document(), here)
    if ok then
        self.dirty = false
        self:markSynced(here.percentage)
    else
        logger.info("Nightstand sync: could not save, will try again:", err)
    end
end

-- events ------------------------------------------------------------------------

function SyncEngine:opened()
    UIManager:nextTick(self.check_task)
end

function SyncEngine:pageTurned()
    self.dirty = true
    if self.checked then
        UIManager:unschedule(self.save_task)
        UIManager:scheduleIn(IDLE_SAVE, self.save_task)
    elseif not self.asking and self.clock() - self.last_try >= RETRY then
        self:check()
    end
end

function SyncEngine:connected()
    if not self.checked then return self:check() end
    if self.dirty then self:save() end
end

--- Closing the book or going to sleep: the last chance to save for a while.
function SyncEngine:leaving()
    self:save()
end

--- Back from sleep: another device may have been read meanwhile.
function SyncEngine:woke()
    self.checked = false
    self.last_try = -math.huge
    UIManager:scheduleIn(2, self.check_task)
end

function SyncEngine:stop()
    UIManager:unschedule(self.save_task)
    UIManager:unschedule(self.check_task)
end

return SyncEngine
