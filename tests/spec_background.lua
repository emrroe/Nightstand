local T = require("t")
local UIManager = require("ui/uimanager")

-- Run the event loop's scheduled callbacks by hand, in order.
local pending = {}
UIManager.nextTick = function(_, fn) table.insert(pending, fn) end
UIManager.scheduleIn = function(_, _secs, fn) table.insert(pending, fn) end
local function drain(limit)
    local n = 0
    while #pending > 0 and n < (limit or 10000) do
        table.remove(pending, 1)()
        n = n + 1
    end
    return n
end

T.describe("background work", function()
    T.it("does every item, in order, one step per tick", function()
        pending = {}
        local B = require("background")
        local seen = {}
        B.run({ 1, 2, 3 }, function(x) table.insert(seen, x) end, { label = "Covers" })
        T.eq(#seen, 0, "nothing happens synchronously")
        drain(1)
        T.eq(seen, { 1 }, "one item per step")
        drain()
        T.eq(seen, { 1, 2, 3 })
        T.ok(not B.running, "idle afterwards")
    end)
    T.it("reports progress for the status line while running", function()
        pending = {}
        local B = require("background")
        B.run({ "a", "b" }, function() end, { label = "Covers" })
        T.eq(B.status(), nil, "not started yet")
        drain(1)
        T.eq(B.status(), "Covers 1/2")
        drain()
        T.eq(B.status(), nil)
    end)
    T.it("a failing item doesn't stop the rest", function()
        pending = {}
        local B = require("background")
        local seen = {}
        B.run({ 1, 2, 3 }, function(x)
            if x == 2 then error("network down") end
            table.insert(seen, x)
        end)
        drain()
        T.eq(seen, { 1, 3 })
    end)
    T.it("queued jobs run one after another, each with its on_done", function()
        pending = {}
        local B = require("background")
        local log = {}
        B.run({ "c1", "c2" }, function(x) table.insert(log, x) end, { on_done = function() table.insert(log, "covers done") end })
        B.run({ "p1" }, function(x) table.insert(log, x) end, { on_done = function() table.insert(log, "positions done") end })
        drain()
        T.eq(log, { "c1", "c2", "covers done", "p1", "positions done" })
    end)
    T.it("redraws every few items and once at the end", function()
        pending = {}
        local B = require("background")
        local redraws = {}
        B.on_progress = function(final) table.insert(redraws, final) end
        B.run({ 1, 2, 3, 4, 5 }, function() end, { redraw_every = 2 })
        drain()
        B.on_progress = nil
        T.eq(redraws, { false, false, false, true }, "after 2, after 4, job end, idle")
    end)
    T.it("nothing to do calls on_done straight away", function()
        pending = {}
        local done = false
        require("background").run({}, function() end, { on_done = function() done = true end })
        T.ok(done)
        T.eq(#pending, 0)
    end)
    T.it("cancel drops what is queued", function()
        pending = {}
        local B = require("background")
        local seen = 0
        B.run({ 1, 2, 3 }, function() seen = seen + 1 end)
        drain(2)
        B.cancel()
        local before = seen
        B.run({ "new" }, function() seen = seen + 1 end)
        drain()
        T.eq(seen, before + 1, "the cancelled job stopped; only the new one ran, once")
        T.ok(not B.running)
    end)
end)

T.finish()
