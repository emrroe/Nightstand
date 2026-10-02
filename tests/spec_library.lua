local T = require("t")

local function t(title, o) o = o or {}; o.title = title; return o end

local function books()
    return {
        t("The Way of Kings", { author = "Brandon Sanderson", series = "Stormlight", series_index = 1,
            added_rank = 5, published = "2010", status = "complete", on_device = true, last_read = 100 }),
        t("Words of Radiance", { author = "Brandon Sanderson", series = "Stormlight", series_index = 2,
            added_rank = 4, published = "2014", status = "reading", last_read = 300 }),
        t("Edgedancer", { author = "Brandon Sanderson", series = "Stormlight", series_index = 2.5,
            added_rank = 3, status = "new" }),
        t("Neuromancer", { author = "William Gibson", added_rank = 1, published = "1984",
            genres = { "Science Fiction" } }),
        t("A Local File", { author = "", on_device = true }),
        t("The Three-Body Problem", { author = "Cixin Liu, Ken Liu", added_rank = 2,
            genres = { "Science Fiction", "Thriller" } }),
    }
end

T.describe("library sorting", function()
    local L
    local function sorted(id, desc) L = require("library"); return T.titles(L.sort(books(), id, desc)) end

    T.it("title ignores leading articles", function()
        T.eq(sorted("title"), { "Edgedancer", "A Local File", "Neuromancer", "The Three-Body Problem",
                                "The Way of Kings", "Words of Radiance" })
    end)
    T.it("recently read puts never-opened books last in both directions", function()
        T.eq(sorted("recent", true)[1], "Words of Radiance")
        T.eq(sorted("recent", false)[1], "The Way of Kings")
        for _, desc in ipairs({ true, false }) do
            local list = sorted("recent", desc)
            T.eq({ list[3], list[4], list[5], list[6] },
                 { "Edgedancer", "A Local File", "Neuromancer", "The Three-Body Problem" },
                 "unknowns keep title order at the end")
        end
    end)
    T.it("date added descending is newest first, unknown last", function()
        T.eq(sorted("added", true), { "Neuromancer", "The Three-Body Problem", "Edgedancer",
                                      "Words of Radiance", "The Way of Kings", "A Local File" })
    end)
    T.it("author sorts by surname, then series order", function()
        T.eq(sorted("author"), { "Neuromancer", "The Three-Body Problem", "The Way of Kings",
                                 "Words of Radiance", "Edgedancer", "A Local File" })
    end)
    T.it("series sorts by name then index, fractional novellas in place", function()
        local list = sorted("series")
        T.eq({ list[1], list[2], list[3] }, { "The Way of Kings", "Words of Radiance", "Edgedancer" })
    end)
    T.it("published, both directions", function()
        T.eq(sorted("published", true)[1], "Words of Radiance")
        T.eq(sorted("published", false)[1], "Neuromancer")
    end)
    T.it("unknown sort id falls back to title instead of erroring", function()
        T.eq(sorted("nonsense"), sorted("title"))
    end)
    T.it("does not reorder the caller's list", function()
        L = require("library")
        local input = books()
        local first = input[1].title
        L.sort(input, "title")
        T.eq(input[1].title, first)
    end)
    T.it("copes with an empty list and entries missing every field", function()
        L = require("library")
        T.eq(#L.sort({}, "recent", true), 0)
        local odd = { {}, { title = "" }, { title = "Z" } }
        for _, sort in ipairs(L.SORTS) do
            T.eq(#L.sort(odd, sort.id, true), 3, sort.id)
            T.eq(#L.sort(odd, sort.id, false), 3, sort.id)
        end
    end)
    T.it("sort is a strict ordering (table.sort never sees an inconsistent comparator)", function()
        L = require("library")
        local many = {}
        for i = 1, 300 do
            many[i] = { title = "Book " .. (i % 17), author = (i % 3 == 0) and "" or ("A" .. i % 5),
                        added_rank = (i % 4 == 0) and nil or i, last_read = (i % 2 == 0) and i or nil,
                        series = (i % 6 == 0) and "S" or nil, series_index = i % 7, book_id = i }
        end
        for _, sort in ipairs(L.SORTS) do
            T.eq(#L.sort(many, sort.id, true), 300)
            T.eq(#L.sort(many, sort.id, false), 300)
        end
    end)
end)

T.describe("library filters", function()
    local function filtered(id) return T.titles(require("library").filter(books(), id)) end
    T.it("all", function() T.eq(#filtered("all"), 6) end)
    T.it("on device", function() T.eq(filtered("device"), { "The Way of Kings", "A Local File" }) end)
    T.it("reading", function() T.eq(filtered("reading"), { "Words of Radiance" }) end)
    T.it("finished", function() T.eq(filtered("finished"), { "The Way of Kings" }) end)
    T.it("unread is everything neither reading nor finished", function()
        T.eq(filtered("unread"), { "Edgedancer", "Neuromancer", "A Local File", "The Three-Body Problem" })
    end)
    T.it("unknown filter id shows everything", function() T.eq(#filtered("bogus"), 6) end)
end)

T.describe("library groups", function()
    local function names(groups)
        local out = {}
        for i, g in ipairs(groups) do out[i] = g.name .. "(" .. #g.books .. ")" end
        return out
    end
    T.it("authors split co-authors and sort by surname; empty author is no group", function()
        T.eq(names(require("library").groups(books(), "authors", "title")),
             { "William Gibson(1)", "Cixin Liu(1)", "Ken Liu(1)", "Brandon Sanderson(3)" })
    end)
    T.it("series groups are always in series order, whatever the sort", function()
        local g = require("library").groups(books(), "series", "title", true)
        T.eq(T.titles(g[1].books), { "The Way of Kings", "Words of Radiance", "Edgedancer" })
    end)
    T.it("a book in two genres appears in both", function()
        T.eq(names(require("library").groups(books(), "genres", "title")),
             { "Science Fiction(2)", "Thriller(1)" })
    end)
    T.it("'books' is not a grouping", function()
        T.eq(require("library").groups(books(), "books", "title"), nil)
    end)
    T.it("no members gives no groups, not an error", function()
        T.eq(#require("library").groups({ { title = "x" } }, "series", "title"), 0)
    end)
    T.it("find falls back to the first option for unknown or nil ids", function()
        local L = require("library")
        T.eq(L.find(L.SORTS, nil).id, "recent")
        T.eq(L.find(L.GROUPS, "gone").id, "books")
    end)
end)

T.finish()
