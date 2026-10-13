--[[--
Slow work (cover downloads, position lookups) done one small step at a time
between UI events, so the screen stays usable while it runs. Each step is a
short blocking call; control goes back to the event loop after every one.
--]]--

local UIManager = require("ui/uimanager")

local Background = {
    queue = {},
    running = false,
    current = nil,   -- the job being worked on, for the status line
}

-- the screen to redraw while work arrives; set by whoever shows it
Background.on_progress = nil

local function finish()
    Background.running, Background.current = false, nil
    if Background.on_progress then Background.on_progress(true) end
end

local step

local function continue(delay)
    if delay then UIManager:scheduleIn(delay, step) else UIManager:nextTick(step) end
end

step = function()
    local job = Background.queue[1]
    if not job then return finish() end
    local item = table.remove(job.items, 1)
    if item == nil then
        table.remove(Background.queue, 1)
        if job.on_done then pcall(job.on_done) end
        if Background.on_progress then Background.on_progress(false) end
        return continue()
    end
    Background.current = job
    local ok, err = pcall(job.work, item)
    if not ok then require("logger").warn("Nightstand: background step failed:", err) end
    job.done = job.done + 1
    job.since_redraw = (job.since_redraw or 0) + 1
    if job.redraw_every and job.since_redraw >= job.redraw_every and Background.on_progress then
        job.since_redraw = 0
        Background.on_progress(false)
    end
    -- a short pause lets taps and repaints through between steps
    continue(0.05)
end

--- Queue `work(item)` for each item. `opts`: label (for the status line),
--- redraw_every (call on_progress after that many items), on_done.
function Background.run(items, work, opts)
    opts = opts or {}
    if #items == 0 then
        if opts.on_done then opts.on_done() end
        return
    end
    local copy = {}
    for i, item in ipairs(items) do copy[i] = item end
    table.insert(Background.queue, {
        items = copy, work = work, label = opts.label, done = 0, total = #copy,
        redraw_every = opts.redraw_every, on_done = opts.on_done,
    })
    if not Background.running then
        Background.running = true
        continue()
    end
end

--- "Covers 5/27", or nil when idle.
function Background.status()
    local job = Background.running and Background.current
    if not job or not job.label then return nil end
    return string.format("%s %d/%d", job.label, job.done, job.total)
end

return Background
