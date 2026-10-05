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
        assert(require("catalog"):refresh())
    end
    return dir
end

local function byTitle(entries)
    local out = {}
    for _, e in ipairs(entries) do out[e.title] = e end
    return out
end

T.describe("books from the local folder only", function()
    T.it("lists local files when there is no catalogue at all", function()
        local dir = setup({ { "Wind and Truth", "Brandon Sanderson" }, { "Dune", "Frank Herbert" } })
        local entries = require("books"):list(dir)
        T.eq(#entries, 2)
        for _, e in ipairs(entries) do
            T.ok(e.on_device, "on device")
            T.ok(e.file and e.checksum, "has file and checksum")
        end
    end)
    T.it("an empty or missing folder gives an empty list, not an error", function()
        local dir = setup()
        T.eq(#require("books"):list(dir), 0)
        T.eq(#require("books"):list(dir .. "/does-not-exist"), 0)
        T.eq(#require("books"):list(""), 0)
    end)
    T.it("ignores files that are not books", function()
        local dir = setup({ { "Real Book", "Someone" } })
        local f = io.open(dir .. "/notes.json", "w"); f:write("{}"); f:close()
        T.eq(#require("books"):list(dir), 1)
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
        local entries = require("books"):list(dir)
        T.eq(#entries, 3)
        local w = byTitle(entries)["Wind and Truth"]
        T.ok(w.on_device, "on device")
        T.eq(w.book_id, 1)
        T.eq(w.series, "Stormlight")
        T.eq(w.series_index, 5)
    end)
    T.it("server-only books carry a download link and are not on the device", function()
        local dir = setup({}, server)
        local d = byTitle(require("books"):list(dir))["Dune"]
        T.ok(not d.on_device)
        T.eq(d.download_url, "/opds/download/3/epub/")
        T.eq(d.status, "new")
    end)
    T.it("read on the server means finished", function()
        local dir = setup({}, server)
        T.eq(byTitle(require("books"):list(dir))["Neuromancer"].status, "complete")
    end)
    T.it("a short title does not claim a file that merely contains it", function()
        local dir = setup({ { "The Hobbit", "J.R.R. Tolkien" } }, {
            { id = 1, title = "It", authors = { "Stephen King" } },
            { id = 2, title = "The Hobbit", authors = { "J.R.R. Tolkien" } } })
        local by = byTitle(require("books"):list(dir))
        T.ok(not by["It"].on_device, "It stays on the server")
        T.ok(by["The Hobbit"].on_device, "The Hobbit is the local file")
    end)
    T.it("a filename with the author after the title still matches", function()
        local dir = Fakes.booksDir()
        Fakes.epub(dir .. "/x/Dune - Frank Herbert.epub", "", "")
        require("settings"):set("books_dir", dir)
        Fakes.cwa(Fakes.library({ { id = 3, title = "Dune", authors = { "Frank Herbert" } } }))
        assert(require("catalog"):refresh())
        local entries = require("books"):list(dir)
        T.eq(#entries, 1)
        T.ok(entries[1].on_device and entries[1].book_id == 3, "matched by title and surname")
    end)
    T.it("two catalogue books with the same title do not both claim one file", function()
        local dir = setup({ { "Untitled", "A" } }, {
            { id = 1, title = "Untitled", authors = { "A" } },
            { id = 2, title = "Untitled", authors = { "B" } } })
        local entries = require("books"):list(dir)
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
        local checksum = Books:list(dir)[1].checksum
        local Progress = require("progress")
        Progress:load()[checksum] = { percentage = 0.42, device = "nova2", timestamp = 1700000000 }
        local e = Books:list(dir)[1]
        T.eq(e.percent, 0.42)
        T.eq(e.status, "reading")
        T.eq(e.device, "nova2")
        T.eq(e.last_read, 1700000000)
    end)
    T.it("a finished position elsewhere marks the book finished", function()
        local dir = setup({ { "Dune", "Frank Herbert" } })
        local Books = require("books")
        local checksum = Books:list(dir)[1].checksum
        require("progress"):load()[checksum] = { percentage = 1, device = "x", timestamp = 1 }
        T.eq(Books:list(dir)[1].status, "complete")
    end)
    T.it("last read is the later of local history and the server", function()
        local dir = setup({ { "Dune", "Frank Herbert" } })
        local Books = require("books")
        local e = Books:list(dir)[1]
        require("progress"):load()[e.checksum] = { percentage = 0.1, timestamp = 100 }
        require("readhistory").hist = { { file = e.file, time = 500 } }
        T.eq(Books:list(dir)[1].last_read, 500)
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

T.describe("positions for books not on this device", function()
    T.it("a server-only book read elsewhere is the current book on an empty device", function()
        local dir = setup({}, {
            { id = 12, title = "Wind and Truth", authors = { "Brandon Sanderson" }, progress = { 0.21, "nova2", 1790000000 } },
            { id = 13, title = "Older Read", authors = { "X" }, progress = { 0.8, "nova2", 1700000000 } },
            { id = 14, title = "Untouched", authors = { "Y" } } })
        local Books = require("books")
        T.eq(require("progress"):refreshAll(Books:list(dir)), 2, "two positions found by book id")
        local entries = Books:list(dir)
        local current, fresh = Books:current(entries)
        T.eq(current.title, "Wind and Truth", "most recently read wins over furthest")
        T.eq(fresh, false)
        T.eq(current.status, "reading")
        T.eq(current.percent, 0.21)
        T.eq(current.device, "nova2")
        T.ok(not current.on_device, "still only on the server")
    end)
    T.it("a wake refresh only asks about the books it is told to", function()
        local dir = setup({}, {
            { id = 12, title = "Wanted", authors = { "A" }, progress = { 0.3 } },
            { id = 13, title = "Skipped", authors = { "B" }, progress = { 0.6 } } })
        local Books = require("books")
        local calls = Fakes.cwa(Fakes.library({
            { id = 12, title = "Wanted", authors = { "A" }, progress = { 0.3 } },
            { id = 13, title = "Skipped", authors = { "B" }, progress = { 0.6 } } }))
        local n = require("progress"):refreshAll(Books:list(dir), function(e) return e.book_id == 12 end)
        T.eq(n, 1)
        for _, path in ipairs(calls) do T.ok(not path:match("/13$"), "no request for 13") end
    end)
    T.it("an older CWA that only knows checksums leaves server-only books alone", function()
        local dir = setup({}, { { id = 12, title = "Wind and Truth", authors = { "B" } } })
        local Books = require("books")
        T.eq(require("progress"):refreshAll(Books:list(dir)), 0)
        local _, fresh = Books:current(Books:list(dir))
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
    T.it("shelves hold unread books only, newest first, never the hero", function()
        local Books = require("books")
        local hero = { title = "hero", status = "reading", percent = 0.5, added = "2026-09", on_device = true }
        local list = { hero,
                       { title = "done", status = "complete", added = "2026-10", on_device = true },
                       { title = "other", status = "reading", percent = 0.2, added = "2026-10", on_device = true },
                       { title = "peeked", status = "reading", percent = 0, added = "2026-08", on_device = true },
                       { title = "new", status = "new", added = "2026-10-03" },
                       { title = "local", status = "new", added = "2026-07", on_device = true } }
        local shelves = Books:shelves(list, hero)
        T.eq(T.titles(shelves[1].books), { "new", "peeked", "local" })
        T.eq(T.titles(shelves[2].books), { "peeked", "local" })
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

T.describe("downloads", function()
    T.it("a server book lands as Author/Title - Author.epub and becomes local", function()
        local dir = setup({}, { { id = 3, title = "Dune", authors = { "Frank Herbert", "Someone Else" } } })
        local Books = require("books")
        local entry = Books:list(dir)[1]
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
        local e = assert(require("catalog"):refresh())[1]
        T.eq(e.download_url, "/opds/download/9/epub/")
        T.eq(e.size, 7)
    end)
    T.it("unsafe characters in titles do not escape the books folder", function()
        local dir = setup({}, { { id = 4, title = "../../etc: a/b?", authors = { "Who/Me" } } })
        local entry = require("books"):list(dir)[1]
        local ok, path = require("download"):book(entry)
        T.ok(ok, tostring(path))
        T.ok(path:sub(1, #dir) == dir and not path:sub(#dir + 1):match("%.%./"),
             "stays inside: " .. path)
    end)
    T.it("missing author and title still give a sensible path", function()
        local dir = setup({}, { { id = 5, title = "", authors = {} } })
        local entry = require("books"):list(dir)[1]
        local ok, path = require("download"):book(entry)
        T.ok(ok, tostring(path))
        T.eq(path, dir .. "/Unknown/Untitled - Unknown.epub")
    end)
    T.it("a failed download reports and changes nothing", function()
        local dir = setup({}, { { id = 6, title = "Gone", authors = { "X" } } })
        local entry = require("books"):list(dir)[1]
        Fakes.cwa({})
        local ok, err = require("download"):book(entry)
        T.eq(ok, false)
        T.ok(err, "has a reason")
        T.ok(not entry.on_device)
    end)
    T.it("no download link and no books folder are reported, not thrown", function()
        local Download = require("download")
        T.eq(Download:book({ title = "x" }), false)
        require("settings"):set("books_dir", "")
        T.eq(Download:book({ title = "x", download_url = "/y" }), false)
    end)
end)

T.finish()
