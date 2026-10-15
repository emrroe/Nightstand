local T = require("t")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

-- Run the event loop's scheduled callbacks by hand, waiting in between like
-- the real loop would, until nothing is scheduled any more.
local pending = {}
UIManager.nextTick = function(_, fn) table.insert(pending, fn) end
UIManager.scheduleIn = function(_, _secs, fn) table.insert(pending, fn) end
local function settle()
    for _round = 1, 200 do
        if #pending == 0 then return true end
        os.execute("sleep 0.05")
        local now = pending
        pending = {}
        for _index, fn in ipairs(now) do fn() end
    end
    return false
end

local dir = os.getenv("HOME") .. "/fetcher"
local function fresh()
    pending = {}
    os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")
    local Fetcher = require("fetcher")
    Fetcher.fork = true
    return Fetcher
end

--- Writes the item's file; item "bad" fails, "slow" takes a while.
local function work(item)
    if item == "bad" then return false end
    if item == "slow" then os.execute("sleep 3") end
    local f = io.open(dir .. "/" .. item, "w")
    f:write(item)
    f:close()
    return true
end

T.describe("fetching in a separate process", function()
    T.it("files arrive, each result is handed back here, and the screen hears of it", function()
        local Fetcher = fresh()
        local results, redraws = {}, {}
        local parent = require("ffi").C.getpid()
        Fetcher.start("covers", { "a", "bad", "b" }, work, {
            label = "Covers",
            on_arrive = function(item, ok)
                T.eq(require("ffi").C.getpid(), parent, "results reach the parent")
                results[item] = ok
            end,
            on_progress = function(final) table.insert(redraws, final) end,
        })
        T.eq(Fetcher.status(), "Covers 0/3", "nothing done yet, nothing waited for")
        T.ok(settle(), "the job finishes")
        T.eq(results, { a = true, bad = false, b = true })
        T.ok(lfs.attributes(dir .. "/a", "mode") == "file" and lfs.attributes(dir .. "/b", "mode") == "file")
        T.eq(redraws[#redraws], true, "a last redraw when done")
        T.eq(Fetcher.status(), nil)
        T.eq(next(Fetcher.jobs), nil)
    end)

    T.it("a new job under the same name stops the old one", function()
        local Fetcher = fresh()
        local old = {}
        Fetcher.start("discover", { "slow", "never" }, work, {
            key = "page 1", on_arrive = function(item) table.insert(old, item) end })
        Fetcher.start("discover", { "c" }, work, { key = "page 2" })
        T.ok(settle(), "the stopped process is collected too")
        T.eq(old, {}, "nothing more from the old job")
        T.ok(lfs.attributes(dir .. "/never", "mode") == nil, "the old job stopped")
        T.ok(lfs.attributes(dir .. "/c", "mode") == "file")
    end)

    T.it("asked again for the same page, it carries on with the new screen's callbacks", function()
        local Fetcher = fresh()
        local first, second = 0, 0
        Fetcher.start("discover", { "d" }, work, { key = "page 1", on_progress = function() first = first + 1 end })
        local pid = Fetcher.jobs.discover.pid
        T.ok(pid, "running in its own process")
        Fetcher.start("discover", { "d" }, work, { key = "page 1", on_progress = function() second = second + 1 end })
        T.eq(Fetcher.jobs.discover.pid, pid, "same process")
        T.ok(settle())
        T.eq(first, 0)
        T.ok(second > 0)
    end)

    T.it("without forking the same job runs on the background queue", function()
        local Fetcher = fresh()
        Fetcher.fork = false
        local results, final = {}, false
        Fetcher.start("covers", { "e", "bad" }, work, {
            on_arrive = function(item, ok) results[item] = ok end,
            on_progress = function(done) final = final or done end,
        })
        T.ok(settle())
        T.eq(results, { e = true, bad = false })
        T.ok(final)
        T.eq(next(Fetcher.jobs), nil)
    end)
end)

T.finish()
