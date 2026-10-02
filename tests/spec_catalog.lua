local T = require("t")
local Fakes = require("fakes")

local function book(id, extra)
    local b = { id = id, title = "Book " .. id, authors = { "Author " .. id },
                uuid = string.format("%08x-0000-4000-8000-%012x", id, id) }
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end

T.describe("catalogue parsing", function()
    T.it("reads every field the screens use", function()
        Fakes.cwa(Fakes.library({ book(2, {
            title = "Baptism of Fire & <Friends>", authors = { "Andrzej Sapkowski", "David French" },
            published = "2014-03-06T00:00:00+00:00", language = "eng",
            genres = { "Fantasy", "Fiction", "General" }, size = 537014,
            summary = "<p>A <b>witcher</b> story.</p>", series = { "The Witcher", 3 } }) }))
        local entries = assert(require("catalog"):refresh())
        local e = entries[1]
        T.eq(e.title, "Baptism of Fire & <Friends>")
        T.eq(e.author, "Andrzej Sapkowski, David French")
        T.eq(e.published, "2014-03-06T00:00:00+00:00")
        T.eq(e.language, "eng")
        T.eq(e.genres, { "Fantasy" }, "catch-all genres are dropped")
        T.eq(e.size, 537014)
        T.eq(e.summary, "A witcher story.", "HTML stripped from the summary")
        T.eq(e.book_id, 2)
        T.eq(e.uuid, "00000002-0000-4000-8000-000000000002")
        T.eq(e.series, "The Witcher")
        T.eq(e.series_index, 3)
        T.eq(e.download_url, "/opds/download/2/epub/")
    end)

    T.it("skips entries without a download link", function()
        Fakes.cwa({ ["/opds/books/letter/00"] = Fakes.feed({
            Fakes.entry(book(1)), Fakes.entry(book(2, { no_download = true })) }) })
        T.eq(#assert(require("catalog"):refresh()), 1)
    end)

    T.it("an empty feed is an error, not an empty library", function()
        Fakes.cwa({ ["/opds/books/letter/00"] = Fakes.feed({}) })
        local entries, err = require("catalog"):refresh()
        T.eq(entries, nil)
        T.ok(err and err:match("no books"), "says why")
    end)

    T.it("an unreachable server is reported and keeps the old catalogue", function()
        Fakes.cwa(Fakes.library({ book(1), book(2) }))
        local Catalog = require("catalog")
        Catalog:refresh()
        Fakes.cwa({})
        local entries, err = Catalog:refresh()
        T.eq(entries, nil)
        T.ok(err, "an error comes back")
        T.eq(Catalog:count(), 2, "previous catalogue still there")
    end)

    T.it("the extras failing only costs their fields", function()
        local routes = Fakes.library({ book(1, { series = { "S", 1 } }) })
        routes["/opds/new"], routes["/opds/series/letter/00"], routes["/opds/readbooks"] = nil, nil, nil
        Fakes.cwa(routes)
        local e = assert(require("catalog"):refresh())[1]
        T.eq(e.added_rank, nil)
        T.eq(e.series, nil)
    end)
end)

T.describe("catalogue paging", function()
    T.it("follows next links through every page, like CWA's 60-book pages", function()
        local books = {}
        for i = 1, 150 do books[i] = book(i) end
        local calls = Fakes.cwa(Fakes.library(books, { page_size = 60 }))
        T.eq(#assert(require("catalog"):refresh()), 150)
        local pages = 0
        for _, path in ipairs(calls) do if path:match("^/opds/books/letter/00") then pages = pages + 1 end end
        T.eq(pages, 3)
    end)

    T.it("a next link pointing back at itself does not loop forever", function()
        Fakes.cwa({ ["/opds/books/letter/00"] = Fakes.feed({ Fakes.entry(book(1)) }, "/opds/books/letter/00") })
        T.eq(#assert(require("catalog"):refresh()), 1)
    end)

    T.it("a failing later page keeps the pages already read", function()
        local books = {}
        for i = 1, 70 do books[i] = book(i) end
        local routes = Fakes.library(books, { page_size = 60 })
        routes["/opds/books/letter/00?offset=60"] = nil
        Fakes.cwa(routes)
        T.eq(#assert(require("catalog"):refresh()), 60)
    end)
end)

T.describe("catalogue extras", function()
    T.it("date-added rank comes from /opds/new order", function()
        Fakes.cwa(Fakes.library({ book(1, { added = 3 }), book(2, { added = 9 }), book(3, { added = 5 }) }))
        local by_id = {}
        for _, e in ipairs(assert(require("catalog"):refresh())) do by_id[e.book_id] = e.added_rank end
        T.eq(by_id, { [2] = 1, [3] = 2, [1] = 3 })
    end)

    T.it("real series numbers, including novellas, from the book JSON", function()
        Fakes.cwa(Fakes.library({ book(1, { series = { "Stormlight", 1 } }),
                                  book(2, { series = { "Stormlight", 2.5 } }),
                                  book(3, { series = { "Stormlight", 5 } }) }))
        local idx = {}
        for _, e in ipairs(assert(require("catalog"):refresh())) do idx[e.book_id] = e.series_index end
        T.eq(idx, { 1, 2.5, 5 })
    end)

    T.it("falls back to the position in the series feed when the JSON is missing", function()
        local routes = Fakes.library({ book(1, { series = { "S", 4 } }), book(2, { series = { "S", 7 } }) })
        routes["/ajax/book/00000001-0000-4000-8000-000000000001"] = nil
        routes["/ajax/book/00000002-0000-4000-8000-000000000002"] = "not json"
        Fakes.cwa(routes)
        local idx = {}
        for _, e in ipairs(assert(require("catalog"):refresh())) do idx[e.book_id] = e.series_index end
        T.eq(idx, { 1, 2 })
    end)

    T.it("an unchanged book reuses its series number instead of asking again", function()
        local calls = Fakes.cwa(Fakes.library({ book(1, { series = { "S", 3 } }) }))
        local Catalog = require("catalog")
        Catalog:refresh()
        local before = #calls
        Catalog:refresh()
        for i = before + 1, #calls do
            T.ok(not calls[i]:match("^/ajax/book/"), "no second JSON request: " .. calls[i])
        end
        T.eq(Catalog:load()[1].series_index, 3)
    end)

    T.it("marks books read on the server", function()
        Fakes.cwa(Fakes.library({ book(1, { read = true }), book(2) }))
        local read = {}
        for _, e in ipairs(assert(require("catalog"):refresh())) do read[e.book_id] = e.read_on_server or false end
        T.eq(read, { true, false })
    end)

    T.it("the catalogue survives a restart (written to disk)", function()
        Fakes.cwa(Fakes.library({ book(1), book(2) }))
        require("catalog"):refresh()
        package.loaded["catalog"] = nil
        T.eq(require("catalog"):count(), 2)
    end)
end)

T.finish()
