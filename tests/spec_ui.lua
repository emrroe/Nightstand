--[[--
Every screen, in every data state, at the screen size run.sh chose: built,
painted, checked that each tap zone lies on screen, then every zone tapped
and the result painted again. Anything that opens a book, the network, or
another app is replaced with a recorder.
--]]--

local T = require("t")
local Fakes = require("fakes")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local W, H = Screen:getWidth(), Screen:getHeight()
local SIZE = os.getenv("SIZE_LABEL") or (W .. "x" .. H)

-- datasets ------------------------------------------------------------------

local function seriesBooks()
    local books = {}
    local function add(b) b.id = #books + 1; table.insert(books, b) end
    for i, t in ipairs({ "The Way of Kings", "Words of Radiance", "Oathbringer", "Rhythm of War", "Wind and Truth" }) do
        add({ title = t, authors = { "Brandon Sanderson" }, series = { "The Stormlight Archive", i },
              genres = { "Fantasy" }, read = i < 3, published = "20" .. (10 + i) .. "-01-01T00:00:00+00:00" })
    end
    add({ title = "Edgedancer", authors = { "Brandon Sanderson" }, series = { "The Stormlight Archive", 2.5 } })
    for i, t in ipairs({ "Blood of Elves", "The Time of Contempt", "Baptism of Fire" }) do
        add({ title = t, authors = { "Andrzej Sapkowski", "David French" }, series = { "The Witcher", i },
              genres = { "Fantasy", "Action" } })
    end
    add({ title = "Neuromancer", authors = { "William Gibson" }, genres = { "Science Fiction" } })
    add({ title = "The Three-Body Problem", authors = { "Cixin Liu", "Ken Liu" }, genres = { "Science Fiction" } })
    add({ title = "No Author Here", authors = {} })
    return books
end

local function hostileBooks(n)
    local books = {}
    local titles = {
        "Ünïcödé Tïtlé — with ‘quotes’ & <tags>",
        string.rep("An Extraordinarily Long Title That Never Seems To End ", 5),
        "", "A", "日本語のタイトル", "Title/With\\Slashes:And?Marks*",
    }
    for i = 1, n do
        books[i] = { id = i, title = titles[i % #titles + 1] .. " " .. i,
                     authors = (i % 5 == 0) and {} or { "Author " .. (i % 37) },
                     series = (i % 3 == 0) and { "Series " .. (i % 11), i } or nil,
                     genres = { "Genre " .. (i % 7) }, read = i % 4 == 0 }
    end
    return books
end

local DATASETS = {}

local function useServer(books, with_covers)
    Fakes.cwa(Fakes.library(books))
    assert(require("catalog"):refresh())
    if with_covers then
        local CoverCache = require("covercache")
        for _, e in ipairs(require("catalog"):load()) do CoverCache:fetchRemote(e.book_id, e.cover_url) end
    end
end

local function useLocal(dir, list)
    for _, b in ipairs(list) do
        Fakes.epub(dir .. "/" .. b[2] .. "/" .. b[1] .. " - " .. b[2] .. ".epub", b[1], b[2])
    end
end

DATASETS["fresh install"] = function()
    require("settings"):set("books_dir", Fakes.booksDir("fresh"))
    require("settings"):set("server", "https://books.example")
end
DATASETS["no books folder"] = function()
    require("settings"):set("books_dir", "")
end
DATASETS["local files only"] = function()
    local dir = Fakes.booksDir("local")
    useLocal(dir, { { "Wind and Truth", "Brandon Sanderson" }, { "Dune", "Frank Herbert" }, { "Emma", "Jane Austen" } })
    require("settings"):set("books_dir", dir)
end
DATASETS["catalogue with covers"] = function()
    require("settings"):set("books_dir", Fakes.booksDir("cat"))
    require("settings"):set("server", "https://books.example")
    useServer(seriesBooks(), true)
end
DATASETS["mixed with positions"] = function()
    local dir = Fakes.booksDir("mixed")
    useLocal(dir, { { "Wind and Truth", "Brandon Sanderson" }, { "Neuromancer", "William Gibson" } })
    require("settings"):set("books_dir", dir)
    require("settings"):set("server", "https://books.example")
    useServer(seriesBooks(), false)
    local Books = require("books")
    for _, e in ipairs(Books:list(dir)) do
        if e.checksum then
            require("progress"):load()[e.checksum] = { percentage = 0.42, device = "nova2", timestamp = os.time() - 60 }
        end
    end
    require("progress"):save()
end
DATASETS["500 hostile books"] = function()
    require("settings"):set("books_dir", Fakes.booksDir("big"))
    require("settings"):set("server", "https://books.example")
    useServer(hostileBooks(500), false)
end
DATASETS["a single book"] = function()
    require("settings"):set("books_dir", Fakes.booksDir("one"))
    useServer({ { id = 1, title = "Only One", authors = { "Solo" } } }, true)
end

-- checks -----------------------------------------------------------------------

local canvas = Blitbuffer.new(W, H, Screen.bb and Screen.bb:getType() or Blitbuffer.TYPE_BB8)

--- After a paint every widget knows where it was drawn; nothing may stick
--- out past the screen, which the outer frame would otherwise clip silently.
local function checkInside(widget, what, depth, seen)
    if type(widget) ~= "table" or seen[widget] or depth > 60 then return end
    seen[widget] = true
    local d = rawget(widget, "dimen")
    -- only leaves: containers record the content's position but their own width
    if widget[1] == nil and type(d) == "table" and d.x and d.w and d.w > 0 and d.h and d.h > 0 then
        T.ok(d.x >= -1 and d.y >= -1 and d.x + d.w <= W + 1 and d.y + d.h <= H + 1,
             string.format("%s: %s drawn at %d,%d %dx%d, outside %dx%d", what,
                           tostring(rawget(widget, "text") or widget.name or "widget"),
                           d.x, d.y, d.w, d.h, W, H))
    end
    for _, child in ipairs(widget) do checkInside(child, what, depth + 1, seen) end
end

local function paint(widget, what)
    canvas:fill(Blitbuffer.COLOR_WHITE)
    widget:paintTo(canvas, 0, 0)
    checkInside(widget, what, 0, {})
    local size = widget[1] and widget[1]:getSize()
    if size then
        T.ok(size.w <= W + 1 and size.h <= H + 1,
             string.format("%s: content %dx%d exceeds screen %dx%d", what, size.w, size.h, W, H))
    end
end

local function checkZones(widget, what)
    T.ok(widget.tap_zones and #widget.tap_zones > 0, what .. ": has tap zones")
    for i, zone in ipairs(widget.tap_zones) do
        local r = zone.rect
        T.ok(r.w > 0 and r.h > 0, string.format("%s: zone %d is empty (%dx%d)", what, i, r.w, r.h))
        T.ok(r.x >= -1 and r.y >= -1 and r.x + r.w <= W + 1 and r.y + r.h <= H + 1,
             string.format("%s: zone %d off screen at %d,%d %dx%d", what, i, r.x, r.y, r.w, r.h))
    end
end

local recorder = {}
local function plugin()
    recorder.calls = {}
    local p = {}
    for _, name in ipairs({ "openTab", "openSettings", "openLibrary", "editServer",
                            "refreshCatalogue", "openKoreaderMenu" }) do
        p[name] = function(_, ...) table.insert(recorder.calls, name) end
    end
    return p
end

local function quiet(screen)
    screen.openBook = function() table.insert(recorder.calls, "openBook") end
    screen.fetchAndOpen = function() table.insert(recorder.calls, "fetchAndOpen") end
    screen.showBlurb = function() table.insert(recorder.calls, "showBlurb") end
    -- menus apply each of their options in turn instead of waiting for a tap
    screen.menu = function(self, _title, list, _current, on_pick)
        for _, spec in ipairs(list) do
            on_pick(spec)
            paint(self, "after menu pick " .. spec.id)
        end
    end
    screen.openLink = function() table.insert(recorder.calls, "openLink") end
    return screen
end

--- Tap the centre of every zone the screen has right now, painting after each.
local function tapAll(screen, what)
    -- a tab tap closes the screen; a closed screen is freed and not painted again
    local close = UIManager.close
    UIManager.close = function(um, widget, ...)
        if widget == screen then screen._closed_by_test = true end
        return close(um, widget, ...)
    end
    local zones = {}
    for i, z in ipairs(screen.tap_zones) do zones[i] = z.rect end
    for i, r in ipairs(zones) do
        local pos = Geom:new{ x = r.x + math.floor(r.w / 2), y = r.y + math.floor(r.h / 2), w = 0, h = 0 }
        local ok, err = xpcall(function() screen:onTap(nil, { pos = pos }) end, debug.traceback)
        T.ok(ok, string.format("%s: tapping zone %d at %d,%d failed:\n%s", what, i, pos.x, pos.y, tostring(err)))
        if screen._closed_by_test then
            -- reopen a fresh copy so the remaining zones still get tapped
            screen._closed_by_test = nil
            screen.free = nil
            (screen.refresh or screen.rebuild)(screen)
        end
        local painted, perr = xpcall(function() paint(screen, what .. " after tap " .. i) end, debug.traceback)
        T.ok(painted, string.format("%s: painting after tapping zone %d at %d,%d failed:\n%s",
                                    what, i, pos.x, pos.y, tostring(perr)))
        checkZones(screen, what .. " after tap " .. i)
    end
    UIManager.close = close
end

-- the screens -------------------------------------------------------------------

for _, name in ipairs({ "fresh install", "no books folder", "local files only", "catalogue with covers",
                        "mixed with positions", "500 hostile books", "a single book" }) do
    T.describe(SIZE .. " › " .. name, function()
        T.it("home paints, zones on screen, every tap survives", function()
            DATASETS[name]()
            local home = quiet(require("homescreen"):new{ plugin = plugin() })
            paint(home, "home")
            checkZones(home, "home")
            tapAll(home, "home")
        end)

        T.it("library: every filter × sort × direction", function()
            DATASETS[name]()
            local Library = require("library")
            local Settings = require("settings")
            for _, f in ipairs(Library.FILTERS) do
                for _, s in ipairs(Library.SORTS) do
                    for _, desc in ipairs({ true, false }) do
                        Settings:set("library_filter", f.id)
                        Settings:set("library_sort", s.id)
                        Settings:set("library_descending", desc)
                        local lib = quiet(require("libraryscreen"):new{ plugin = plugin() })
                        local what = string.format("library %s/%s/%s", f.id, s.id, tostring(desc))
                        paint(lib, what)
                        checkZones(lib, what)
                        lib:free()
                    end
                end
            end
        end)

        T.it("library: every grouping, every group opened, every page turned", function()
            DATASETS[name]()
            local Library = require("library")
            for _, g in ipairs(Library.GROUPS) do
                for _, f in ipairs(Library.FILTERS) do
                    require("settings"):set("library_group", g.id)
                    require("settings"):set("library_filter", f.id)
                    local lib = quiet(require("libraryscreen"):new{ plugin = plugin() })
                    local what = "library " .. g.id .. "/" .. f.id
                    paint(lib, what)
                    checkZones(lib, what)
                    for _ = 1, lib.pages + 1 do lib:turnPage(1); paint(lib, what .. " paged") end
                    if lib.showing_groups then
                        local groups = {}
                        for i, group in ipairs(lib.items) do groups[i] = group end
                        for _, group in ipairs(groups) do
                            lib:activate(group)
                            paint(lib, what .. " › " .. group.name)
                            checkZones(lib, what .. " › " .. group.name)
                            for _ = 1, lib.pages + 1 do lib:turnPage(1); paint(lib, what .. " group paged") end
                            T.ok(lib:onClose(), "back out of the group")
                            T.eq(lib.open_group, nil, "back leaves the group")
                        end
                    end
                    lib:free()
                end
            end
        end)

        T.it("library: every tap survives", function()
            DATASETS[name]()
            for _, g in ipairs({ "books", "series" }) do
                require("settings"):set("library_group", g)
                local lib = quiet(require("libraryscreen"):new{ plugin = plugin() })
                paint(lib, "library")
                tapAll(lib, "library " .. g)
                lib:free()
            end
        end)

        T.it("discover (and home with four tabs): paints, zones on screen, every tap and hold survives", function()
            DATASETS[name]()
            local server = Fakes.hardcover()
            local Hardcover = require("hardcover")
            local device = Hardcover:startLink()
            T.eq(Hardcover:poll(device.device_code), "linked")
            Hardcover:fetchMe()
            local Discover = require("discover")
            Discover.fetchCover = function(self, book)
                if not book.image_url then return false end
                local path = self:coverFile(book.hc_id, book.image_url)
                os.execute("mkdir -p '" .. path:match("^(.*)/") .. "'")
                local f = io.open(path, "wb"); f:write(Fakes.png()); f:close()
                return true
            end
            assert(Discover:refresh("Wind and Truth"))
            for id = 1, 12 do
                local book = Discover:load().books[id]
                if book then Discover:fetchCover(book) end
            end

            local home = quiet(require("homescreen"):new{ plugin = plugin() })
            paint(home, "home linked")
            checkZones(home, "home linked")

            local screen = require("discoverscreen"):new{ plugin = plugin() }
            paint(screen, "discover")
            checkZones(screen, "discover")
            tapAll(screen, "discover")
            for i, z in ipairs(screen.tap_zones) do
                if z.hold then
                    local pos = Geom:new{ x = z.rect.x + 1, y = z.rect.y + 1, w = 0, h = 0 }
                    local ok, err = xpcall(function() screen:onHold(nil, { pos = pos }) end, debug.traceback)
                    T.ok(ok, "hold on zone " .. i .. ": " .. tostring(err))
                end
            end
            -- every list, every page, and the Want to read view
            for _, spec in ipairs(screen:availableLists()) do
                screen:showList(spec.id)
                for _ = 1, screen.pages + 1 do screen:turnPage(1); paint(screen, "discover " .. spec.id) end
            end
            screen:showList("want")
            paint(screen, "discover want")
            checkZones(screen, "discover want")
            T.ok(screen:onClose(), "back leaves Want to read")
            T.ok(screen.list ~= "want")
            -- want-to-read round trip through the screen
            screen:toggleWanted(screen.entries[1])
            paint(screen, "discover after want")
            T.ok(server, "server used")
        end)

        T.it("settings: unlinked, linked and unavailable, every tap survives", function()
            DATASETS[name]()
            local Hardcover = require("hardcover")
            local server = Fakes.hardcover()
            for _, state in ipairs({ "unlinked", "linked", "unavailable" }) do
                if state == "linked" then
                    local device = Hardcover:startLink()
                    T.eq(Hardcover:poll(device.device_code), "linked")
                    Hardcover:fetchMe()
                elseif state == "unavailable" then
                    Hardcover:forget()
                    Hardcover.CLIENT_ID = ""
                end
                local screen = quiet(require("settingsscreen"):new{ plugin = plugin() })
                paint(screen, "settings " .. state)
                checkZones(screen, "settings " .. state)
                tapAll(screen, "settings " .. state)
            end
            T.ok(server, "server used")
        end)
    end)
end

T.describe(SIZE .. " › hardcover sign-in screen", function()
    T.it("each state paints: starting, waiting, slow down, expired, declined, linked", function()
        Fakes.hardcover({ pending = 1, slow_down = true })
        local HardcoverLink = require("hardcoverlink")
        local screen = HardcoverLink:new{}
        paint(screen, "link starting")
        screen:start()
        T.eq(screen.state, "waiting")
        paint(screen, "link waiting")
        screen:pollOnce()
        T.eq(screen.interval, 10, "slow_down backs off by five seconds")
        paint(screen, "link after slow_down")
        screen.deadline = os.time() - 1
        screen:pollOnce()
        T.eq(screen.state, "expired")
        paint(screen, "link expired")
        screen:restart()
        screen:start()
        screen.state, screen.message = "error", "Sign-in was declined."
        screen:rebuild()
        paint(screen, "link declined")
        screen:cancelPoll()
        screen:onCloseWidget()
        T.ok(screen.closed, "closing stops polling")
    end)
    T.it("an approved link stores the account and the username", function()
        Fakes.hardcover({ pending = 0 })
        local screen = require("hardcoverlink"):new{}
        screen:start()
        screen:pollOnce()
        T.eq(screen.state, "linked")
        T.eq(require("hardcover"):username(), "reader")
        paint(screen, "link linked")
        screen:onCloseWidget()
    end)
    T.it("starting offline shows an error instead of throwing", function()
        local server = Fakes.hardcover()
        server.online = false
        local screen = require("hardcoverlink"):new{}
        screen:start()
        T.eq(screen.state, "error")
        paint(screen, "link offline")
    end)
end)

T.describe(SIZE .. " › opening a book", function()
    T.it("closes every Nightstand screen, so closing the book brings Home back", function()
        DATASETS["local files only"]()
        local opened
        package.loaded["apps/reader/readerui"] = { showReader = function(_, file) opened = file end }
        local show = UIManager.show
        UIManager.show = function() end
        local Screen = require("screen")
        local home = require("homescreen"):new{ plugin = plugin() }
        local library = require("libraryscreen"):new{ plugin = plugin() }
        local book
        for _index, e in ipairs(library.items) do if e.on_device then book = e break end end
        T.ok(book, "a local book to open")
        require("bookactions").open(library, book)
        UIManager.show = show
        package.loaded["apps/reader/readerui"] = nil
        T.eq(opened, book.file, "the reader got the book")
        T.eq(next(Screen.open_screens), nil, "no Nightstand screen left open underneath")
        T.ok(home, "home existed")
    end)
end)

T.describe(SIZE .. " › first run", function()
    local function boot(online, routes)
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr.isOnline = function() return online end
        local shown = {}
        local show, nextTick = UIManager.show, UIManager.nextTick
        UIManager.show = function(_, w) table.insert(shown, w) end
        UIManager.nextTick = function(_, f) f() end
        if routes then Fakes.cwa(routes) end
        local ok, err = xpcall(function()
            local Nightstand = require("main")
            local menu = { registerToMainMenu = function() end }
            local ui = { menu = menu, registerPostInitCallback = function(_, f) f() end }
            Nightstand:new{ ui = ui }
        end, debug.traceback)
        UIManager.show, UIManager.nextTick = show, nextTick
        T.ok(ok, tostring(err))
        return shown
    end
    T.it("online with an empty catalogue: fetches the library and shows it", function()
        DATASETS["fresh install"]()
        local shown = boot(true, Fakes.library(seriesBooks()))
        T.eq(require("catalog"):count(), 12, "catalogue fetched")
        local home
        for _, w in ipairs(shown) do if w.name == "nightstand_home" then home = w end end
        T.ok(home, "home screen shown")
        T.ok(#home.entries == 12, "home lists the fetched books")
        paint(home, "first-run home")
    end)
    T.it("offline with an empty catalogue: shows the empty home without fetching", function()
        DATASETS["fresh install"]()
        local calls = Fakes.cwa({})
        local shown = boot(false)
        T.eq(#calls, 0, "no requests while offline")
        T.ok(#shown >= 1, "home still shown")
    end)
    T.it("server unreachable on first run: still shows home", function()
        DATASETS["fresh install"]()
        local shown = boot(true, {})
        T.ok(#shown >= 1, "home shown despite the failed fetch")
    end)
    T.it("no books folder: stays out of the way", function()
        DATASETS["no books folder"]()
        local shown = boot(true, {})
        for _, w in ipairs(shown) do T.ok(w.name ~= "nightstand_home", "no home without a folder") end
    end)
end)

T.finish()
