local T = require("t")
local Fakes = require("fakes")

local function setup(local_books, server_books)
    local dir = Fakes.booksDir()
    for _, b in ipairs(local_books or {}) do
        Fakes.epub(dir .. "/" .. b[2] .. "/" .. b[1] .. " - " .. b[2] .. ".epub", b[1], b[2])
    end
    require("settings"):set("books_dir", dir)
    if server_books then
        Fakes.cwa(Fakes.library(server_books))
        assert(Fakes.refreshCatalogue())
    end
    return dir
end

-- These tests change positions and settings behind the list's back, so
-- every list is built afresh.
local function list(dir)
    local Books = require("books")
    Books:invalidate()
    return Books:list(dir)
end

local function byTitle(entries)
    local out = {}
    for _, e in ipairs(entries) do out[e.title] = e end
    return out
end

T.describe("books from the local folder only", function()
    T.it("lists local files when there is no catalogue at all", function()
        local dir = setup({ { "Wind and Truth", "Brandon Sanderson" }, { "Dune", "Frank Herbert" } })
        local entries = list(dir)
        T.eq(#entries, 2)
        for _, e in ipairs(entries) do
            T.ok(e.on_device, "on device")
            T.ok(e.file and e.checksum, "has file and checksum")
        end
    end)
    T.it("an empty or missing folder gives an empty list, not an error", function()
        local dir = setup()
        T.eq(#list(dir), 0)
        T.eq(#list(dir .. "/does-not-exist"), 0)
        T.eq(#list(""), 0)
    end)
    T.it("ignores files that are not books", function()
        local dir = setup({ { "Real Book", "Someone" } })
        local f = io.open(dir .. "/notes.json", "w"); f:write("{}"); f:close()
        T.eq(#list(dir), 1)
    end)
end)

T.describe("books merged with the catalogue", function()
    local server = {
        { id = 1, title = "Wind and Truth", authors = { "Brandon Sanderson" }, series = { "Stormlight", 5 } },
        { id = 2, title = "Neuromancer", authors = { "William Gibson" }, read = true },
        { id = 3, title = "Dune", authors = { "Frank Herbert" } },
    }
    T.it("a local file and its catalogue entry become one book", function()
        local dir = setup({ { "Wind and Truth", "Brandon Sanderson" } }, server)
        local entries = list(dir)
        T.eq(#entries, 3)
        local w = byTitle(entries)["Wind and Truth"]
        T.ok(w.on_device, "on device")
        T.eq(w.book_id, 1)
        T.eq(w.series, "Stormlight")
        T.eq(w.series_index, 5)
    end)
    T.it("server-only books carry a download link and are not on the device", function()
        local dir = setup({}, server)
        local d = byTitle(list(dir))["Dune"]
        T.ok(not d.on_device)
        T.eq(d.download_url, "/opds/download/3/epub/")
        T.eq(d.status, "new")
    end)
    T.it("read on the server means finished", function()
        local dir = setup({}, server)
        T.eq(byTitle(list(dir))["Neuromancer"].status, "complete")
    end)
    T.it("a short title does not claim a file that merely contains it", function()
        local dir = setup({ { "The Hobbit", "J.R.R. Tolkien" } }, {
            { id = 1, title = "It", authors = { "Stephen King" } },
            { id = 2, title = "The Hobbit", authors = { "J.R.R. Tolkien" } } })
        local by = byTitle(list(dir))
        T.ok(not by["It"].on_device, "It stays on the server")
        T.ok(by["The Hobbit"].on_device, "The Hobbit is the local file")
    end)
    T.it("a filename with the author after the title still matches", function()
        local dir = Fakes.booksDir()
        Fakes.epub(dir .. "/x/Dune - Frank Herbert.epub", "", "")
        require("settings"):set("books_dir", dir)
        Fakes.cwa(Fakes.library({ { id = 3, title = "Dune", authors = { "Frank Herbert" } } }))
        assert(Fakes.refreshCatalogue())
        local entries = list(dir)
        T.eq(#entries, 1)
        T.ok(entries[1].on_device and entries[1].book_id == 3, "matched by title and surname")
    end)
    T.it("two catalogue books with the same title do not both claim one file", function()
        local dir = setup({ { "Untitled", "A" } }, {
            { id = 1, title = "Untitled", authors = { "A" } },
            { id = 2, title = "Untitled", authors = { "B" } } })
        local entries = list(dir)
        T.eq(#entries, 2)
        local local_count = 0
        for _, e in ipairs(entries) do if e.on_device then local_count = local_count + 1 end end
        T.eq(local_count, 1)
    end)
end)

T.describe("reading positions", function()
    T.it("a position read elsewhere wins when it is further along", function()
        local dir = setup({ { "Wind and Truth", "Brandon Sanderson" } })
        local Books = require("books")
        local checksum = list(dir)[1].checksum
        local Progress = require("progress")
        Progress:load()[checksum] = { percentage = 0.42, device = "nova2", timestamp = 1700000000 }
        local e = list(dir)[1]
        T.eq(e.percent, 0.42)
        T.eq(e.status, "reading")
        T.eq(e.device, "nova2")
        T.eq(e.last_read, 1700000000)
    end)
    T.it("the most recent position wins, whichever device saved it and whichever way it moved", function()
        local dir = setup({ { "Dune", "Frank Herbert" } })
        local Books = require("books")
        local file = list(dir)[1].file
        local DocSettings = require("docsettings")
        local settings = DocSettings:open(file)
        settings:saveSetting("percent_finished", 0.5)
        settings:flush()
        -- KOReader refreshes this cache itself when a book closes
        require("ui/widget/booklist").resetBookInfoCache(file)
        local lfs = require("libs/libkoreader-lfs")
        lfs.touch(DocSettings:findSidecarFile(file), 1000, 1000)
        local checksum = list(dir)[1].checksum
        local Progress = require("progress")
        Progress:load()[checksum] = { percentage = 0.2, progress = "/body/DocFragment[3].0",
                                       device = "nova2", device_id = "nova", timestamp = 2000 }
        local e = list(dir)[1]
        T.eq(e.percent, 0.2, "the Nova went back a chapter later: that is where the book is")
        T.eq(e.device, "nova2")
        T.eq(e.remote.progress, "/body/DocFragment[3].0", "kept so opening can go there")
        Progress:load()[checksum].timestamp = 500
        e = list(dir)[1]
        T.eq(e.percent, 0.5, "this device read more recently")
        T.eq(e.remote, nil)
        T.eq(e.device, nil)
    end)
    T.it("this device's own save on the server is not news", function()
        local dir = setup({ { "Dune", "Frank Herbert" } })
        local Books = require("books")
        local checksum = list(dir)[1].checksum
        G_reader_settings:saveSetting("device_id", "me")
        require("progress"):load()[checksum] = { percentage = 0.7, device = "phone", device_id = "me",
                                                 timestamp = os.time() + 100 }
        local e = list(dir)[1]
        T.eq(e.remote, nil)
        T.eq(e.device, nil)
        G_reader_settings:delSetting("device_id")
    end)
    T.it("opening from Home goes to the newer position, and leaves the sync nothing to ask", function()
        local dir = setup({ { "Dune", "Frank Herbert" } })
        local Books = require("books")
        local entry = list(dir)[1]
        entry.remote = { percentage = 0.3, progress = "/body/DocFragment[4].0", device = "nova2",
                         device_id = "nova", timestamp = 4242 }
        package.loaded["apps/reader/readerui"] = { showReader = function() end }
        require("bookactions").open(nil, entry)
        package.loaded["apps/reader/readerui"] = nil
        local settings = require("docsettings"):open(entry.file)
        T.eq(settings:readSetting("last_xpointer"), "/body/DocFragment[4].0")
        T.eq(settings:readSetting("nightstand_sync_seen"), 4242, "the sync treats this one as answered")
    end)
    T.it("opening from Home keeps a place this device read to offline, for the reader to ask about", function()
        local dir = setup({ { "Dune", "Frank Herbert" } })
        local entry = list(dir)[1]
        local DocSettings = require("docsettings")
        local settings = DocSettings:open(entry.file)
        settings:saveSetting("last_xpointer", "/body/DocFragment[9].0")
        settings:saveSetting("percent_finished", 0.6)
        settings:flush()
        entry.remote = { percentage = 0.3, progress = "/body/DocFragment[4].0", device = "nova2",
                         device_id = "nova", timestamp = 4242 }
        package.loaded["apps/reader/readerui"] = { showReader = function() end }
        require("bookactions").open(nil, entry)
        settings = DocSettings:open(entry.file)
        T.eq(settings:readSetting("last_xpointer"), "/body/DocFragment[9].0", "never sent to the server")
        T.eq(settings:readSetting("nightstand_sync_seen"), nil, "so the sync still asks")
        settings:saveSetting("nightstand_synced", 0.6)
        settings:flush()
        require("bookactions").open(nil, entry)
        package.loaded["apps/reader/readerui"] = nil
        settings = DocSettings:open(entry.file)
        T.eq(settings:readSetting("last_xpointer"), "/body/DocFragment[4].0", "the server knew it: go to the newer one")
    end)
    T.it("a finished position elsewhere marks the book finished", function()
        local dir = setup({ { "Dune", "Frank Herbert" } })
        local Books = require("books")
        local checksum = list(dir)[1].checksum
        require("progress"):load()[checksum] = { percentage = 1, device = "x", timestamp = 1 }
        T.eq(list(dir)[1].status, "complete")
    end)
    T.it("last read is the later of local history and the server", function()
        local dir = setup({ { "Dune", "Frank Herbert" } })
        local Books = require("books")
        local e = list(dir)[1]
        require("progress"):load()[e.checksum] = { percentage = 0.1, timestamp = 100 }
        require("readhistory").hist = { { file = e.file, time = 500 } }
        T.eq(list(dir)[1].last_read, 500)
        require("readhistory").hist = {}
    end)
    T.it("the hero is the furthest book in progress, else a suggestion", function()
        local Books = require("books")
        local cur, fresh = Books:current({ { title = "a", status = "reading", percent = 0.2 },
                                          { title = "b", status = "reading", percent = 0.7 },
                                          { title = "c", status = "new" } })
        T.eq(cur.title, "b"); T.eq(fresh, false)
        cur, fresh = Books:current({ { title = "c", status = "new" } })
        T.eq(cur.title, "c"); T.eq(fresh, true)
        cur = Books:current({ { title = "old", status = "new", added_rank = 9 },
                              { title = "S1", series = "S", series_index = 1, status = "complete" },
                              { title = "S2", series = "S", series_index = 2, status = "new", added_rank = 5 },
                              { title = "newest", status = "new", added_rank = 1 } })
        T.eq(cur.title, "S2", "the next in a series beats the newest addition")
        cur = Books:current({ { title = "old", status = "new", added_rank = 9 },
                              { title = "newest", status = "new", added_rank = 1 } })
        T.eq(cur.title, "newest", "else the newest addition")
        cur = Books:current({ { title = "older file", status = "new", added = "2026-01-01" },
                              { title = "newer file", status = "new", added = "2026-09-01" } })
        T.eq(cur.title, "newer file", "a books folder without a server: the newest file")
        cur = Books:current({})
        T.eq(cur, nil, "no books, no hero")
    end)
    T.it("progress tags", function()
        local Books = require("books")
        T.eq(Books:progressTag({ status = "complete" }), "Finished")
        T.eq(Books:progressTag({ status = "new" }), "New")
        T.eq(Books:progressTag({ status = "reading", percent = 0.214 }), "21%")
        T.eq(Books:progressTag({}), "New")
    end)
end)

--- Ask the server about each book, as the background refresh does.
local function refreshPositions(entries)
    local Progress, found = require("progress"), 0
    for _, entry in ipairs(entries) do
        if Progress:refreshEntry(entry) then found = found + 1 end
    end
    return found
end

T.describe("positions for books not on this device", function()
    T.it("a server-only book read elsewhere is the current book on an empty device", function()
        local dir = setup({}, {
            { id = 12, title = "Wind and Truth", authors = { "Brandon Sanderson" }, progress = { 0.21, "nova2", 1790000000 } },
            { id = 13, title = "Older Read", authors = { "X" }, progress = { 0.8, "nova2", 1700000000 } },
            { id = 14, title = "Untouched", authors = { "Y" } } })
        local Books = require("books")
        T.eq(refreshPositions(list(dir)), 2, "two positions found by book id")
        local entries = list(dir)
        local current, fresh = Books:current(entries)
        T.eq(current.title, "Wind and Truth", "most recently read wins over furthest")
        T.eq(fresh, false)
        T.eq(current.status, "reading")
        T.eq(current.percent, 0.21)
        T.eq(current.device, "nova2")
        T.ok(not current.on_device, "still only on the server")
    end)
    T.it("an older CWA that only knows checksums leaves server-only books alone", function()
        local dir = setup({}, { { id = 12, title = "Wind and Truth", authors = { "B" } } })
        local Books = require("books")
        T.eq(refreshPositions(list(dir)), 0)
        local _, fresh = Books:current(list(dir))
        T.eq(fresh, true, "falls back to a suggestion")
    end)
end)

T.describe("next in series", function()
    local function b(title, series, index, status, last_read)
        return { title = title, series = series, series_index = index, status = status, last_read = last_read }
    end
    T.it("the first untouched book after the furthest one read", function()
        local Books = require("books")
        local list = { b("S1", "S", 1, "complete", 10), b("S2", "S", 2, "complete", 20),
                       b("S2.5", "S", 2.5, "new"), b("S3", "S", 3, "new") }
        T.eq(T.titles(Books:nextInSeries(list)), { "S2.5" })
    end)
    T.it("nothing for unstarted series, finished series, or the hero itself", function()
        local Books = require("books")
        local hero = b("W2", "W", 2, "new")
        local list = { b("U1", "U", 1, "new"), b("F1", "F", 1, "complete"),
                       b("W1", "W", 1, "reading", 5), hero }
        T.eq(#Books:nextInSeries(list, hero), 0)
    end)
    T.it("most recently read series first", function()
        local Books = require("books")
        local list = { b("A1", "A", 1, "complete", 10), b("A2", "A", 2, "new"),
                       b("B1", "B", 1, "complete", 99), b("B2", "B", 2, "new") }
        T.eq(T.titles(Books:nextInSeries(list)), { "B2", "A2" })
    end)
end)

T.describe("home shelves", function()
    T.it("a book opened but not read is not the one being read", function()
        local Books = require("books")
        local cur, fresh = Books:current({ { title = "peeked", status = "reading", percent = 0.002, last_read = 99 },
                                          { title = "real", status = "reading", percent = 0.3, last_read = 1 } })
        T.eq(cur.title, "real"); T.eq(fresh, false)
        cur, fresh = Books:current({ { title = "peeked", status = "reading", percent = 0, added_rank = 1 } })
        T.eq(fresh, true, "only peeked at: a suggestion, not progress")
    end)
    T.it("always the same two shelves, empty ones kept with something to say", function()
        local Books = require("books")
        local shelves = Books:shelves({}, nil)
        T.eq(#shelves, 2)
        T.eq(shelves[1].label, "Recently added")
        T.eq(shelves[2].label, "Ready on this device")
        for _, shelf in ipairs(shelves) do
            T.eq(#shelf.books, 0)
            T.ok(shelf.empty and #shelf.empty > 0, shelf.label .. " explains itself when empty")
        end
    end)
    T.it("new on the server and ready here never overlap; the hero is on neither", function()
        require("settings"):set("server", "https://books.example")
        local Books = require("books")
        local hero = { title = "hero", status = "reading", percent = 0.5, added = "2026-09", on_device = true }
        local list = { hero,
                       { title = "done", status = "complete", added = "2026-10", on_device = true },
                       { title = "other", status = "reading", percent = 0.2, added = "2026-06", on_device = true,
                         last_read = 5 },
                       { title = "peeked", status = "reading", percent = 0, added = "2026-08", on_device = true },
                       { title = "new", status = "new", added = "2026-10-03" },
                       { title = "elsewhere", status = "reading", percent = 0.4, added = "2026-10-04" },
                       { title = "local", status = "new", added = "2026-10-05", on_device = true } }
        local shelves = Books:shelves(list, hero)
        T.eq(T.titles(shelves[1].books), { "new" })
        T.eq(T.titles(shelves[2].books), { "other", "local", "peeked" }, "under way first, then newest")
    end)
end)

T.describe("books without a server", function()
    T.it("an EPUB's own package gives title, authors, series, number and description", function()
        local EpubMeta = require("epubmeta")
        local calibre = EpubMeta.parse([[<package><metadata>
            <dc:title>Edgedancer</dc:title><dc:creator>Brandon Sanderson</dc:creator>
            <dc:description>&lt;p&gt;Lift &amp;amp; Wyndle&lt;/p&gt;</dc:description><dc:date>2016-10-04</dc:date>
            <meta name="calibre:series" content="The Stormlight Archive"/>
            <meta content="2.5" name="calibre:series_index"/></metadata></package>]])
        T.eq(calibre.title, "Edgedancer")
        T.eq(calibre.series, "The Stormlight Archive")
        T.eq(calibre.series_index, 2.5)
        T.eq(calibre.summary, "Lift & Wyndle")
        T.eq(calibre.published, "2016-10-04")
        local epub3 = EpubMeta.parse([[<metadata><dc:title>Two</dc:title>
            <dc:creator>A</dc:creator><dc:creator>B</dc:creator>
            <meta property="belongs-to-collection" id="c1">Saga</meta>
            <meta refines="#c1" property="group-position">2</meta></metadata>]])
        T.eq(epub3.author, "A, B")
        T.eq(epub3.series, "Saga")
        T.eq(epub3.series_index, 2)
    end)
    T.it("a book never opened still gets its real title and author, and a date added", function()
        local dir = setup({ { "Real Title", "Some Author" } })
        local entries = list(dir)
        T.eq(entries[1].title, "Real Title")
        T.eq(entries[1].author, "Some Author")
        T.ok(entries[1].added, "dated by when the file arrived")
    end)
    T.it("without a server, Recently added is the newest books in the folder", function()
        local Books = require("books")
        local shelves = Books:shelves({ { title = "local", status = "new", added = "2026-10-05", on_device = true } })
        T.eq(T.titles(shelves[1].books), { "local" })
        T.ok(shelves[1].empty:find("books folder"))
    end)
end)

T.describe("over Wi-Fi only", function()
    T.it("blocks downloads on mobile data only when the setting is on", function()
        local Net = require("net")
        local Settings = require("settings")
        Net.onMobileData = function() return true end
        Settings:set("wifi_only", true)
        T.eq(Net.mayDownload(), false)
        Settings:set("wifi_only", false)
        T.eq(Net.mayDownload(), true)
        Net.onMobileData = function() return false end
        Settings:set("wifi_only", true)
        T.eq(Net.mayDownload(), true, "Wi-Fi is fine")
    end)
    T.it("off Android there is no mobile data", function()
        T.eq(require("net").onMobileData(), false)
    end)
end)

T.describe("the list", function()
    T.it("is reused until something it was built from changes", function()
        local dir = setup({ { "Dune", "Frank Herbert" } })
        local Books = require("books")
        local first = Books:list(dir)
        T.eq(Books:list(dir), first, "nothing changed")
        require("progress"):remember("x", { percentage = 0.5 })
        local second = Books:list(dir)
        T.ok(second ~= first, "a new position")
        Books:invalidate()
        T.ok(Books:list(dir) ~= second, "a book was read")
        local third = Books:list(dir)
        Books.cached.at = os.time() - 60
        T.ok(Books:list(dir) ~= third, "and after a while anyway")
    end)
end)

T.describe("covers", function()
    T.it("only so many sizes are kept in memory, the least recently used going first", function()
        local Blitbuffer = require("ffi/blitbuffer")
        local CoverCache = require("covercache")
        local image = Blitbuffer.new(60, 90, Blitbuffer.TYPE_BB8)
        image:writePNG(CoverCache:coverFile(1))
        image:free()
        local entry = { book_id = 1 }
        local first = CoverCache:get(entry, 20, 30)
        T.ok(first, "a cover")
        for w = 21, 220 do
            CoverCache:get(entry, w, 30)
            CoverCache:get(entry, 20, 30)  -- still on screen
        end
        local slots = 0
        for _ in pairs(CoverCache.cache) do slots = slots + 1 end
        T.ok(slots <= 160, "capped, holds " .. slots)
        T.eq(CoverCache:get(entry, 20, 30), first, "the one in use stays")
        T.eq(CoverCache.cache["id:1|21x30"], nil, "an old size went")
    end)
    T.it("a cover that could not be read is tried again later", function()
        local CoverCache = require("covercache")
        local entry = { file = "/nowhere/book.epub" }
        T.eq(CoverCache:get(entry, 20, 30), nil)
        T.ok(CoverCache.misses[entry.file], "remembered as missing")
        local tried = false
        local BookInfo = require("apps/filemanager/filemanagerbookinfo")
        local real = BookInfo.getCoverImage
        BookInfo.getCoverImage = function() tried = true end
        CoverCache:get(entry, 20, 30)
        T.ok(not tried, "not asked again at once")
        CoverCache.misses[entry.file] = os.time() - 600
        CoverCache:get(entry, 20, 30)
        BookInfo.getCoverImage = real
        T.ok(tried, "asked again after a while")
    end)
end)

T.describe("downloads", function()
    T.it("a server book lands as Author/Title - Author.epub and becomes local", function()
        local dir = setup({}, { { id = 3, title = "Dune", authors = { "Frank Herbert", "Someone Else" } } })
        local Books = require("books")
        local entry = list(dir)[1]
        local ok, path = require("download"):book(entry)
        T.ok(ok, tostring(path))
        T.eq(path, dir .. "/Frank Herbert/Dune - Frank Herbert.epub")
        T.ok(entry.on_device and entry.checksum, "entry updated in place")
        T.eq(require("availability").map[entry.checksum], path, "availability knows")
    end)
    T.it("a PDF-only book is saved as .pdf, and a missing books folder is created", function()
        local dir = Fakes.booksDir() .. "/not/there/yet"
        require("settings"):set("books_dir", dir)
        local routes = Fakes.library({ { id = 7, title = "Manual", authors = { "Acme" } } })
        routes["/opds/download/7/pdf/"] = "PDFDATA"
        Fakes.cwa(routes)
        local entry = { title = "Manual", author = "Acme", download_url = "/opds/download/7/pdf/" }
        local ok, path = require("download"):book(entry)
        T.ok(ok, tostring(path))
        T.eq(path, dir .. "/Acme/Manual - Acme.pdf")
    end)
    T.it("EPUB is chosen when a book comes in several formats", function()
        Fakes.cwa({ ["/opds/books/letter/00"] = Fakes.feed({ [[<entry><title>Two</title>
            <link rel="http://opds-spec.org/acquisition" href="/opds/download/9/pdf/" length="5" type="application/pdf"/>
            <link rel="http://opds-spec.org/acquisition" href="/opds/download/9/epub/" length="7" type="application/epub+zip"/>
            </entry>]] }) })
        local e = assert(Fakes.refreshCatalogue())[1]
        T.eq(e.download_url, "/opds/download/9/epub/")
        T.eq(e.size, 7)
    end)
    T.it("unsafe characters in titles do not escape the books folder", function()
        local dir = setup({}, { { id = 4, title = "../../etc: a/b?", authors = { "Who/Me" } } })
        local entry = list(dir)[1]
        local ok, path = require("download"):book(entry)
        T.ok(ok, tostring(path))
        T.ok(path:sub(1, #dir) == dir and not path:sub(#dir + 1):match("%.%./"),
             "stays inside: " .. path)
    end)
    T.it("missing author and title still give a sensible path", function()
        local dir = setup({}, { { id = 5, title = "", authors = {} } })
        local entry = list(dir)[1]
        local ok, path = require("download"):book(entry)
        T.ok(ok, tostring(path))
        T.eq(path, dir .. "/Unknown/Untitled - Unknown.epub")
    end)
    T.it("a failed download reports and changes nothing", function()
        local dir = setup({}, { { id = 6, title = "Gone", authors = { "X" } } })
        local entry = list(dir)[1]
        Fakes.cwa({})
        local ok, err = require("download"):book(entry)
        T.eq(ok, false)
        T.ok(err, "has a reason")
        T.ok(not entry.on_device)
    end)
    T.it("a download cut off halfway leaves nothing to mistake for the book", function()
        local dir = Fakes.booksDir()
        local Settings = require("settings")
        Settings:set("books_dir", dir)
        Settings:set("server", "https://cwa.test")
        local http = require("socket.http")
        local real = http.request
        local cut = true
        http.request = function(req)
            req.sink("PK half a book")
            if cut then return nil, "closed" end
            req.sink(" and the rest")
            req.sink(nil)
            return 1, 200, {}, "200 OK"
        end
        local Download = require("download")
        local entry = { title = "Dune", author = "Frank Herbert", download_url = "/opds/download/3/epub/" }
        local dest = dir .. "/Frank Herbert/Dune - Frank Herbert.epub"
        local ok = Download:book(entry)
        local lfs = require("libs/libkoreader-lfs")
        T.eq(ok, false)
        T.eq(lfs.attributes(dest, "mode"), nil, "no truncated book")
        T.eq(lfs.attributes(dest .. ".part", "mode"), nil, "and no leftover")
        cut = false
        local path
        ok, path = Download:book(entry)
        http.request = real
        T.ok(ok, tostring(path))
        local f = io.open(dest, "rb")
        T.eq(f:read("*a"), "PK half a book and the rest", "fetched again, whole")
        f:close()
    end)
    T.it("a download the reader stops is neither an error nor a book", function()
        local dir = setup({}, { { id = 3, title = "Dune", authors = { "Frank Herbert" } } })
        local entry = list(dir)[1]
        local ok, err = require("download"):book(entry, function() return false end)
        T.eq(ok, nil)
        T.eq(err, nil)
        T.ok(not entry.on_device)
        T.eq(require("libs/libkoreader-lfs").attributes(dir .. "/Frank Herbert/Dune - Frank Herbert.epub"), nil)
        ok, err = require("download"):book(entry, function() return true end)
        T.eq(ok, false, "a transfer process that died says so")
        T.ok(err)
    end)
    T.it("no download link and no books folder are reported, not thrown", function()
        local Download = require("download")
        T.eq(Download:book({ title = "x" }), false)
        require("settings"):set("books_dir", "")
        T.eq(Download:book({ title = "x", download_url = "/y" }), false)
    end)
end)

T.describe("the books folder", function()
    T.it("a link back to a parent folder is read once, not in circles", function()
        local dir = Fakes.booksDir("loop")
        Fakes.epub(dir .. "/A/Book - A.epub", "Book", "A")
        os.execute("ln -s .. '" .. dir .. "/A/up'")
        local Availability = require("availability")
        Availability:invalidate()
        local map = Availability:ensure(dir)
        local n = 0
        for _key in pairs(map) do n = n + 1 end
        T.eq(n, 1)
        T.ok(not select(2, next(map)):find("/up/"), "the book found by its own path")
    end)
    T.it("what a removed book said about itself is forgotten", function()
        local dir = Fakes.booksDir("forget")
        local gone = Fakes.epub(dir .. "/Gone - A.epub", "Gone", "A")
        Fakes.epub(dir .. "/Kept - A.epub", "Kept", "A")
        list(dir)
        local EpubMeta = require("epubmeta")
        T.ok(EpubMeta.store:readSetting(gone))
        os.remove(gone)
        require("availability"):invalidate()
        require("books"):invalidate()
        list(dir)
        T.eq(EpubMeta.store:readSetting(gone), nil)
        T.ok(EpubMeta.store:readSetting(dir .. "/Kept - A.epub"))
    end)
end)

T.finish()
