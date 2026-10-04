local T = require("t")
local Fakes = require("fakes")
local UIManager = require("ui/uimanager")
local rapidjson = require("rapidjson")

local NetworkMgr = require("ui/network/manager")
NetworkMgr.isOnline = function() return true end

local shown = {}
UIManager.show = function(_, widget) table.insert(shown, widget) end
UIManager.close = function() end

local XP = "/body/DocFragment[52].0"

local function record(percentage, device, extra)
    local r = { percentage = percentage, progress = XP, device = device or "nova2",
                device_id = (device or "nova2") .. "-id", timestamp = 1759300000 }
    for k, v in pairs(extra or {}) do r[k] = v end
    return rapidjson.encode(r)
end

local function fresh()
    local Progress = require("progress")
    Progress.records, Progress.history = {}, {}
    shown = {}
end

local function book(name)
    local dir = Fakes.booksDir(name)
    local file = dir .. "/Book - Author.epub"
    Fakes.epub(file, "Book", "Author")
    return file
end

--- A stand-in for the sync plugin: the parts the guard calls.
local function fakeSync(here)
    local sync = { device_id = "phone-id", here = here, pushed = 0 }
    function sync:updateProgress() self.pushed = self.pushed + 1 end
    function sync:getDocumentDigest() return "phonesum" end
    function sync:getLastPercent() return self.here end
    function sync:syncToProgress(progress) self.went = progress end
    return sync
end

T.describe("a fresh download opens where the book was left", function()
    T.it("writes the server position into the new copy", function()
        fresh()
        local file = book("seed")
        Fakes.cwa({ ["/kosync/syncs/progress/13"] = record(0.2077) })
        T.ok(require("syncguard").seedDownload({ book_id = 13 }, file))
        local settings = require("docsettings"):open(file)
        T.eq(settings:readSetting("last_xpointer"), XP)
        T.eq(settings:readSetting("percent_finished"), 0.2077)
        T.eq(settings:readSetting("cre_dom_version"),
             require("document/credocument"):engineInit().getLatestDomVersion(),
             "no migration question for a book never opened")
    end)
    T.it("the newer of the checksum's and the book id's position wins", function()
        fresh()
        local file = book("newer")
        local sum = require("util").partialMD5(file)
        Fakes.cwa({
            ["/kosync/syncs/progress/13"] = record(0.1, "old", { timestamp = 100, progress = "/body/DocFragment[3].0" }),
            ["/kosync/syncs/progress/" .. sum] = record(0.3, "new", { timestamp = 200 }),
        })
        require("syncguard").seedDownload({ book_id = 13 }, file)
        T.eq(require("docsettings"):open(file):readSetting("last_xpointer"), XP)
    end)
    T.it("nothing known, nothing written; a book with a position keeps it", function()
        fresh()
        local file = book("none")
        Fakes.cwa({})
        T.eq(require("syncguard").seedDownload({ book_id = 13 }, file), false)
        local SyncGuard = require("syncguard")
        T.ok(SyncGuard.seed(file, { progress = "/body/DocFragment[9].0", percentage = 0.5 }))
        T.eq(SyncGuard.seed(file, { progress = XP, percentage = 0.2 }), false)
        T.ok(SyncGuard.seed(file, { progress = XP, percentage = 0.2 }, true), "a restore overrides")
    end)
    T.it("a position picked to restore beats the server's, once", function()
        fresh()
        local file = book("chosen")
        Fakes.cwa({ ["/kosync/syncs/progress/13"] = record(0.004, "FP4") })
        local Progress = require("progress")
        Progress:choose(13, { percentage = 0.2077, progress = XP })
        require("syncguard").seedDownload({ book_id = 13 }, file)
        T.eq(require("docsettings"):open(file):readSetting("percent_finished"), 0.2077)
        T.eq(Progress:chosen(13), nil, "used up")
    end)
end)

T.describe("the sync plugin never silently moves another device back", function()
    T.it("pushes when the server is behind, empty, or this device's own", function()
        local SyncGuard = require("syncguard")
        for _, routes in ipairs({
            {},
            { ["/kosync/syncs/progress/phonesum"] = record(0.1) },
            { ["/kosync/syncs/progress/phonesum"] = record(0.9, "phone", { device_id = "phone-id" }) },
        }) do
            fresh()
            Fakes.cwa(routes)
            local sync = fakeSync(0.2)
            SyncGuard.attach({ cwasync = sync })
            sync:updateProgress(false, false)
            T.eq(sync.pushed, 1)
            T.eq(#shown, 0, "no question")
        end
    end)
    T.it("asks when another device is further on, and checks only once", function()
        fresh()
        local calls = Fakes.cwa({ ["/kosync/syncs/progress/phonesum"] = record(0.21) })
        local sync = fakeSync(0.004)
        require("syncguard").attach({ cwasync = sync })
        sync:updateProgress(false, false)
        T.eq(sync.pushed, 0, "held back")
        T.eq(#shown, 1, "asked")
        sync:updateProgress(false, false)
        T.eq(#shown, 1, "asked once at a time")
        shown[1].ok_callback()
        T.eq(sync.went, XP, "went to the other device's place")
        local before = #calls
        sync:updateProgress(false, false)
        T.eq(sync.pushed, 1, "pushes freely afterwards")
        T.eq(#calls, before, "without asking the server again")
    end)
    T.it("keeping this device's position pushes it on purpose", function()
        fresh()
        Fakes.cwa({ ["/kosync/syncs/progress/phonesum"] = record(0.21) })
        local sync = fakeSync(0.004)
        require("syncguard").attach({ cwasync = sync })
        sync:updateProgress(false, false)
        shown[1].cancel_callback()
        T.eq(sync.pushed, 1)
        T.eq(sync.went, nil)
    end)
    T.it("stays quiet when going to sleep", function()
        fresh()
        Fakes.cwa({ ["/kosync/syncs/progress/phonesum"] = record(0.21) })
        local sync = fakeSync(0.004)
        require("syncguard").attach({ cwasync = sync })
        sync:updateProgress(true, false, true)
        T.eq(sync.pushed, 0)
        T.eq(#shown, 0)
    end)
    T.it("a manual push is never held back", function()
        fresh()
        Fakes.cwa({ ["/kosync/syncs/progress/phonesum"] = record(0.21) })
        local sync = fakeSync(0.004)
        require("syncguard").attach({ cwasync = sync })
        sync:updateProgress(false, true)
        T.eq(sync.pushed, 1)
    end)
end)

T.describe("earlier positions", function()
    T.it("are remembered per book, one per place reached, newest first", function()
        fresh()
        local Progress = require("progress")
        local routes = { ["/kosync/syncs/progress/13"] = record(0.21, "nova2", { timestamp = 100 }) }
        Fakes.cwa(routes)
        local entry = { book_id = 13 }
        Progress:refreshEntry(entry)
        Progress:refreshEntry(entry)
        routes["/kosync/syncs/progress/13"] = record(0.004, "FP4", { timestamp = 200 })
        Progress:refreshEntry(entry)
        local list = Progress:positions(entry)
        T.eq(#list, 2)
        T.eq(list[1].device, "FP4")
        T.eq(list[2].percentage, 0.21)
    end)
    T.it("restoring a server-only book opens the download there", function()
        fresh()
        local BookActions = require("bookactions")
        local opened
        BookActions.open = function(_, entry) opened = entry end
        BookActions.restore(nil, { book_id = 13 }, { percentage = 0.21, progress = XP })
        T.eq(require("progress"):chosen(13).percentage, 0.21)
        T.ok(opened)
    end)
    T.it("a push reaches the server as this device", function()
        fresh()
        local calls = Fakes.cwa({})
        T.ok(require("progress"):push("phonesum", { percentage = 0.21, progress = XP }))
        T.eq(calls[#calls], "PUT phonesum")
    end)
end)

T.finish()
