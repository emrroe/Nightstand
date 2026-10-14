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

-- Scheduled callbacks run when the test says so.
local pending = {}
UIManager.scheduleIn = function(_, _secs, fn) table.insert(pending, fn) end
UIManager.nextTick = function(_, fn) table.insert(pending, fn) end
UIManager.unschedule = function(_, fn)
    for i = #pending, 1, -1 do if pending[i] == fn then table.remove(pending, i) end end
end
local function drain()
    while #pending > 0 do table.remove(pending, 1)() end
end

G_reader_settings:saveSetting("device_id", "phone-id")

--- A stand-in for an open book in the reader: the parts the engine uses.
local function reader(percentage)
    local settings = {}
    local ui = {
        here = percentage, events = {},
        document = { info = { has_pages = false }, file = "/books/b.epub" },
        doc_settings = {
            readSetting = function(_, key) return settings[key] end,
            saveSetting = function(_, key, value) settings[key] = value end,
        },
    }
    settings.partial_md5_checksum = "booksum"
    ui.rolling = {
        getLastProgress = function() return "/body/DocFragment[1].0#" .. ui.here end,
        getLastPercent = function() return ui.here end,
    }
    function ui:handleEvent(event) table.insert(self.events, event) end
    return ui
end

--- An engine on `ui` whose network and clock the test controls.
local function engine(ui, net)
    net = net or { online = true, time = 1000 }
    local e = require("syncengine").new(ui, {
        online = function() return net.online end,
        clock = function() return net.time end,
    })
    return e, net
end

local function puts(calls)
    local n = 0
    for _, c in ipairs(calls) do if c:match("^PUT") then n = n + 1 end end
    return n
end

T.describe("a fresh download opens where the book was left", function()
    T.it("writes the server position into the new copy", function()
        fresh()
        local file = book("seed")
        Fakes.cwa({ ["/kosync/syncs/progress/13"] = record(0.2077) })
        T.ok(require("progress"):seedDownload({ book_id = 13 }, file))
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
        require("progress"):seedDownload({ book_id = 13 }, file)
        T.eq(require("docsettings"):open(file):readSetting("last_xpointer"), XP)
    end)
    T.it("nothing known, nothing written; a book with a position keeps it", function()
        fresh()
        local file = book("none")
        Fakes.cwa({})
        T.eq(require("progress"):seedDownload({ book_id = 13 }, file), false)
        local Progress = require("progress")
        T.ok(Progress:seed(file, { progress = "/body/DocFragment[9].0", percentage = 0.5 }))
        T.eq(Progress:seed(file, { progress = XP, percentage = 0.2 }), false)
        T.ok(Progress:seed(file, { progress = XP, percentage = 0.2 }, true), "a restore overrides")
    end)
    T.it("only CWA is asked by its own book id", function()
        fresh()
        local file = book("public")
        local calls = Fakes.cwa({ ["/kosync/syncs/progress/13"] = record(0.2077) })
        local SyncServer = require("syncserver")
        local cwa = SyncServer.current
        SyncServer.current = function()
            return { kind = "public", url = "https://sync.test", username = "reader", userkey = "k" }
        end
        T.eq(require("progress"):seedDownload({ book_id = 13 }, file), false)
        SyncServer.current = cwa
        for _, c in ipairs(calls) do T.ok(c ~= "GET 13", "asked for the CWA id") end
        T.eq(#calls, 1, "the checksum only")
    end)
    T.it("a position picked to restore beats the server's, once", function()
        fresh()
        local file = book("chosen")
        Fakes.cwa({ ["/kosync/syncs/progress/13"] = record(0.004, "FP4") })
        local Progress = require("progress")
        Progress:choose(13, { percentage = 0.2077, progress = XP })
        require("progress"):seedDownload({ book_id = 13 }, file)
        T.eq(require("docsettings"):open(file):readSetting("percent_finished"), 0.2077)
        T.eq(Progress:chosen(13), nil, "used up")
    end)
end)

T.describe("nothing is saved before this device has compared with the server", function()
    T.it("reading offline saves nothing; reconnecting asks before anything is saved", function()
        fresh(); pending = {}
        local calls = Fakes.cwa({ ["/kosync/syncs/progress/booksum"] = record(0.40) })
        local ui = reader(0.01)
        local e, net = engine(ui, { online = false, time = 1000 })
        e:opened(); drain()
        for _ = 1, 5 do ui.here = ui.here + 0.002; e:pageTurned() end
        e:leaving(); drain()
        T.eq(#calls, 0, "offline: no request at all")
        net.online = true
        e:connected()
        T.eq(calls[#calls], "GET booksum", "compared first")
        T.eq(#shown, 1, "asked, although this device turned pages more recently")
        T.eq(puts(calls), 0, "nothing saved while asking")
        e:pageTurned(); e:leaving(); drain()
        T.eq(puts(calls), 0, "still nothing saved while the question is open")
        shown[1].cancel_callback()
        T.eq(puts(calls), 1, "keeping this device's place saves it")
    end)
    T.it("the page shown while the book is still opening neither asks nor counts as reading", function()
        fresh(); pending = {}
        local calls = Fakes.cwa({ ["/kosync/syncs/progress/booksum"] = record(0.40) })
        local e = engine(reader(0.03))
        e:pageTurned()
        T.eq(#calls, 0, "not asked while the reader is being built")
        T.eq(#shown, 0)
        e:opened(); drain()
        T.eq(#shown, 1, "asked once the reader is up")
    end)
    T.it("going to the other device's place moves the reader and saves nothing yet", function()
        fresh(); pending = {}
        local calls = Fakes.cwa({ ["/kosync/syncs/progress/booksum"] = record(0.40) })
        local ui = reader(0.03)
        local e = engine(ui)
        e:opened(); drain()
        shown[1].ok_callback()
        T.eq(ui.events[1].handler, "onGotoXPointer")
        T.eq(ui.events[1].args[1], XP)
        T.eq(puts(calls), 0)
        e:pageTurned(); drain()
        T.eq(puts(calls), 1, "reading on from there saves as usual")
    end)
    T.it("asks whichever way the other device moved", function()
        fresh(); pending = {}
        Fakes.cwa({ ["/kosync/syncs/progress/booksum"] = record(0.05) })
        local e = engine(reader(0.30))
        e:opened(); drain()
        T.eq(#shown, 1, "the other device went back: still asked")
    end)
    T.it("no question for this device's own save, an empty server or the same place", function()
        for name, rec in pairs({
            own = record(0.40, "phone", { device_id = "phone-id" }),
            same = record(0.301),
            none = false,
        }) do
            fresh(); pending = {}
            local calls = Fakes.cwa(rec and { ["/kosync/syncs/progress/booksum"] = rec } or {})
            local ui = reader(0.30)
            local e = engine(ui)
            e:opened(); drain()
            T.eq(#shown, 0, name .. ": no question")
            e:pageTurned(); drain()
            T.eq(puts(calls), 1, name .. ": saves after reading")
        end
    end)
    T.it("a position already answered for is not asked about again", function()
        fresh(); pending = {}
        Fakes.cwa({ ["/kosync/syncs/progress/booksum"] = record(0.40) })
        local ui = reader(0.03)
        engine(ui):opened(); drain()
        shown[1].cancel_callback()
        Fakes.cwa({ ["/kosync/syncs/progress/booksum"] = record(0.40) })
        shown = {}
        engine(ui):opened(); drain()
        T.eq(#shown, 0, "reopening the book: the same old position is not a new question")
    end)
    T.it("a server that cannot be reached is tried again, and nothing is saved meanwhile", function()
        fresh(); pending = {}
        local calls = Fakes.cwa({ ["/kosync/syncs/progress/booksum"] = record(0.40) })
        Fakes.sync_unreachable = true
        local e, net = engine(reader(0.03))
        e:opened(); drain()
        e:pageTurned(); e:leaving(); drain()
        Fakes.sync_unreachable = false
        require("syncserver").reach = nil  -- as if the five quiet minutes had passed
        T.eq(#calls, 0)
        e:pageTurned()
        T.eq(#calls, 0, "not hammered on every page")
        net.time = net.time + 31
        e:pageTurned()
        T.eq(calls[1], "GET booksum", "tried again after a while")
        T.eq(#shown, 1)
    end)
    T.it("waking up compares again: another device may have been read meanwhile", function()
        fresh(); pending = {}
        local calls = Fakes.cwa({})
        local ui = reader(0.10)
        local e = engine(ui)
        e:opened(); drain()
        e:pageTurned(); drain()
        T.eq(puts(calls), 1)
        Fakes.cwa({ ["/kosync/syncs/progress/booksum"] = record(0.25, "nova2", { timestamp = os.time() + 60 }) })
        e:woke(); drain()
        T.eq(#shown, 1, "the Nova read on while this device slept")
    end)
    T.it("closing the book or sleeping saves, but only online", function()
        fresh(); pending = {}
        local calls = Fakes.cwa({})
        local ui = reader(0.10)
        local e, net = engine(ui)
        e:opened(); drain()
        e:pageTurned()
        net.online = false
        e:leaving()
        T.eq(puts(calls), 0)
        T.eq(ui.doc_settings:readSetting("nightstand_synced"), nil, "the server does not know this place")
        net.online = true
        e:leaving()
        T.eq(puts(calls), 1)
        T.eq(ui.doc_settings:readSetting("nightstand_synced"), 0.10, "now it does")
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
        T.ok(require("syncserver").put("phonesum", { percentage = 0.21, progress = XP }))
        T.eq(calls[#calls], "PUT phonesum")
    end)
end)

T.finish()
