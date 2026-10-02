--[[--
Sorting, filtering and grouping for the Library tab.

Kept free of widgets so the rules can be checked on their own. Books missing a
sort key (a local file the server doesn't know, a book never opened) always go
last, whichever way the sort runs, and ties fall back to title.
--]]--

local Library = {}

-- ids are written to settings; labels are what the menus show
Library.SORTS = {
    { id = "recent",    label = "Recently read", desc = true },
    { id = "title",     label = "Title" },
    { id = "author",    label = "Author" },
    { id = "added",     label = "Date added",    desc = true },
    { id = "published", label = "Published",     desc = true },
    { id = "series",    label = "Series" },
}

Library.FILTERS = {
    { id = "all",      label = "All" },
    { id = "device",   label = "On device" },
    { id = "reading",  label = "Reading" },
    { id = "unread",   label = "Unread" },
    { id = "finished", label = "Finished" },
}

Library.GROUPS = {
    { id = "books",   label = "Books" },
    { id = "authors", label = "Authors" },
    { id = "series",  label = "Series" },
    { id = "genres",  label = "Genres" },
}

function Library.find(list, id)
    for _, item in ipairs(list) do
        if item.id == id then return item end
    end
    return list[1]
end

local function sortTitle(title)
    title = (title or ""):lower()
    return (title:gsub("^the ", ""):gsub("^an? ", ""))
end

--- "Brandon Sanderson, Ken Liu" -> { "Brandon Sanderson", "Ken Liu" }
function Library.authors(entry)
    local out = {}
    for name in (entry.author or ""):gmatch("[^,]+") do
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" then table.insert(out, name) end
    end
    return out
end

local function surnameKey(name)
    local last = name:match("(%S+)$") or name
    return (last .. " " .. name):lower()
end

local function firstAuthorKey(entry)
    local first = Library.authors(entry)[1]
    return first and surnameKey(first)
end

-- primary key per sort; nil means "unknown, put it last"
local KEYS = {
    recent    = function(e) return e.last_read end,
    title     = function(e) return sortTitle(e.title) end,
    author    = firstAuthorKey,
    -- rank 1 is the newest addition, so it is negated to sort like a date
    added     = function(e) return e.added_rank and -e.added_rank end,
    published = function(e) return e.published end,
    series    = function(e) return e.series and e.series:lower() end,
}

local function seriesOrder(a, b)
    if a.series ~= b.series or not a.series then return nil end
    if a.series_index ~= b.series_index then
        return (a.series_index or math.huge) < (b.series_index or math.huge)
    end
    return nil
end

function Library.comparator(sort_id, descending)
    local key = KEYS[sort_id] or KEYS.title
    return function(a, b)
        local ka, kb = key(a), key(b)
        if ka ~= kb then
            if ka == nil then return false end
            if kb == nil then return true end
            if descending then return ka > kb end
            return ka < kb
        end
        -- an author's books, or a series, read in series order
        local by_series = seriesOrder(a, b)
        if by_series ~= nil then return by_series end
        local ta, tb = sortTitle(a.title), sortTitle(b.title)
        if ta ~= tb then return ta < tb end
        return tostring(a.book_id or a.file) < tostring(b.book_id or b.file)
    end
end

local TESTS = {
    all      = function() return true end,
    device   = function(e) return e.on_device end,
    reading  = function(e) return e.status == "reading" end,
    unread   = function(e) return e.status ~= "reading" and e.status ~= "complete" end,
    finished = function(e) return e.status == "complete" end,
}

function Library.filter(entries, filter_id)
    local test = TESTS[filter_id] or TESTS.all
    local out = {}
    for _, entry in ipairs(entries) do
        if test(entry) then table.insert(out, entry) end
    end
    return out
end

function Library.sort(entries, sort_id, descending)
    local out = {}
    for i, entry in ipairs(entries) do out[i] = entry end
    table.sort(out, Library.comparator(sort_id, descending))
    return out
end

local MEMBERSHIP = {
    authors = Library.authors,
    series  = function(e) return e.series and { e.series } or {} end,
    genres  = function(e) return e.genres or {} end,
}

--- Groups as { name, books }, sorted by name (authors by surname). Books in
--- a series group are always in series order; the rest follow the chosen sort.
function Library.groups(entries, group_id, sort_id, descending)
    local members = MEMBERSHIP[group_id]
    if not members then return nil end
    local by_name, groups = {}, {}
    for _, entry in ipairs(entries) do
        for _, name in ipairs(members(entry)) do
            local group = by_name[name]
            if not group then
                group = { name = name, books = {} }
                by_name[name] = group
                table.insert(groups, group)
            end
            table.insert(group.books, entry)
        end
    end
    local name_key = group_id == "authors" and surnameKey
        or function(name) return sortTitle(name) end
    table.sort(groups, function(a, b) return name_key(a.name) < name_key(b.name) end)
    for _, group in ipairs(groups) do
        if group_id == "series" then
            group.books = Library.sort(group.books, "series", false)
        else
            group.books = Library.sort(group.books, sort_id, descending)
        end
    end
    return groups
end

return Library
