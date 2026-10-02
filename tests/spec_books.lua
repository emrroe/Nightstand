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

T.describe("downloads", function()
    T.it("a server book lands as Author/Title - Author.epub and becomes local", function()
        local dir = setup({}, { { id = 3, title = "Dune", authors = { "Frank Herbert", "Someone Else" } } })
        local Books = require("books")
        local entry = Books:list(dir)[1]
        local ok, path = require("download"):book(entry)
        T.ok(ok, tostring(path))
        T.eq(path, dir .. "/Frank Herbert/Dune - Frank Herbert.epub")
        T.ok(entry.on_device and entry.checksum, "entry updated in place")
        T.ok(require("availability"):isLocal(entry.checksum), "availability knows")
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
