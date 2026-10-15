--[[--
Cover downloads in a forked copy of KOReader, so the screen never waits on
the network. KOReader's Lua has no threads; its cover browser fetches
thumbnails the same way.

The child only writes files and reports "index ok" lines down a pipe. The
parent looks in once a second and hands each result to the caller there, so
everything that touches memory or settings stays in this process.
--]]--

local ffi = require("ffi")
local C = ffi.C
require("ffi/posix_h")
local Background = require("background")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("ffi/util")

local Fetcher = {
    jobs = {},     -- name -> job; a new job under a name replaces the old
    fork = true,   -- false runs jobs on the Background queue instead
}

local POLL = 1
local polling = false
local reaping = {}   -- pids of stopped children not collected yet
local poll

local function keepPolling()
    if polling then return end
    polling = true
    UIManager:scheduleIn(POLL, poll)
end

local function readAvailable(fd)
    local size = util.getNonBlockingReadSize(fd)
    if not size or size <= 0 then return "" end
    local buffer = ffi.new("char[?]", size)
    local got = tonumber(C.read(fd, buffer, size))
    return got > 0 and ffi.string(buffer, got) or ""
end

local function report(job, item, ok)
    job.done = job.done + 1
    if job.on_arrive then pcall(job.on_arrive, item, ok) end
end

poll = function()
    local redraws = {}
    for name, job in pairs(Fetcher.jobs) do
        if job.pid then
            -- asked before reading, so lines written just before exiting are not missed
            local finished = util.isSubProcessDone(job.pid)
            local arrived = false
            for index, ok in readAvailable(job.fd):gmatch("(%d+) (%d)\n") do
                report(job, job.items[tonumber(index)], ok == "1")
                arrived = true
            end
            if finished then
                C.close(job.fd)
                Fetcher.jobs[name] = nil
                UIManager:allowStandby()
            end
            if (arrived or finished) and job.on_progress then
                table.insert(redraws, { job.on_progress, finished })
            end
        end
    end
    for i = #reaping, 1, -1 do
        if util.isSubProcessDone(reaping[i]) then table.remove(reaping, i) end
    end
    polling = false
    if next(Fetcher.jobs) or #reaping > 0 then keepPolling() end
    -- last: a redraw may start the next job
    for _index, redraw in ipairs(redraws) do pcall(redraw[1], redraw[2]) end
end

local function onQueue(job, work)
    Background.run(job.items, function(item)
        if job.stopped then return end
        local ok, fetched = pcall(work, item)
        report(job, item, ok and fetched == true)
        if job.on_progress then job.on_progress(false) end
    end, {
        on_done = function()
            if job.stopped then return end
            for name, running in pairs(Fetcher.jobs) do
                if running == job then Fetcher.jobs[name] = nil end
            end
            if job.on_progress then job.on_progress(true) end
        end,
    })
end

--- Run `work(item)` -- true when it fetched -- for each item out of process.
--- `opts`: label (for the status line); key: asked again with the same key
--- while running, the job carries on and only takes the new callbacks;
--- on_arrive(item, ok) per item; on_progress(final) after results arrive.
function Fetcher.start(name, items, work, opts)
    opts = opts or {}
    local running = Fetcher.jobs[name]
    if running and opts.key ~= nil and running.key == opts.key then
        running.on_arrive, running.on_progress = opts.on_arrive, opts.on_progress
        return
    end
    Fetcher.stop(name)
    if #items == 0 then return end
    local job = {
        items = {}, key = opts.key, label = opts.label, done = 0, total = #items,
        on_arrive = opts.on_arrive, on_progress = opts.on_progress,
    }
    for i, item in ipairs(items) do job.items[i] = item end
    Fetcher.jobs[name] = job

    if Fetcher.fork then
        local pid, fd = util.runInSubProcess(function(_pid, write_fd)
            for index, item in ipairs(job.items) do
                local ok, fetched = pcall(work, item)
                util.writeToFD(write_fd, string.format("%d %d\n", index, (ok and fetched == true) and 1 or 0))
            end
            C.close(write_fd)
        end, true)
        if pid then
            job.pid, job.fd = pid, fd
            UIManager:preventStandby()
            keepPolling()
            return
        end
        logger.warn("Nightstand: no download process, fetching in turn instead:", fd)
    end
    onQueue(job, work)
end

--- Stop a job; what it already fetched stays.
function Fetcher.stop(name)
    local job = Fetcher.jobs[name]
    if not job then return end
    Fetcher.jobs[name] = nil
    job.stopped = true
    if job.pid then
        util.terminateSubProcess(job.pid)
        C.close(job.fd)
        UIManager:allowStandby()
        table.insert(reaping, job.pid)
        keepPolling()
    end
end

--- "Covers 5/27" for a labelled job, or nil.
function Fetcher.status()
    for _name, job in pairs(Fetcher.jobs) do
        if job.label then return string.format("%s %d/%d", job.label, job.done, job.total) end
    end
end

return Fetcher
