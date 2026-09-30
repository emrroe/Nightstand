--[[--
The shelf, as the home screen needs it.

For now every entry comes from the local folder. When the catalogue lands,
server-only books join the same list with `on_device = false`.
--]]--

local BookList = require("ui/widget/booklist")
local DocSettings = require("docsettings")
local Availability = require("availability")

local Books = {}

local function baseName(path)
    local name = path:match("([^/]+)$") or path
    return (name:gsub("%.%w+$", ""))
end

--- Title and author, without opening the document.
local function propsFor(file)
    if not DocSettings:hasSidecarFile(file) then return nil end
    local ok, props = pcall(function()
        return DocSettings:open(file):readSetting("doc_props")
    end)
    return ok and props or nil
end

function Books:entryFor(file, checksum)
    local info = BookList.getBookInfo(file)
    local props = propsFor(file)
    local title = props and (props.display_title or props.title)
    if not title or title == "" then title = baseName(file) end
    return {
        file = file,
        checksum = checksum,
        title = title,
        author = props and props.authors or "",
        pages = info and info.pages,
        percent = info and info.percent_finished,
        status = BookList.getBookStatus(file),
        on_device = true,
    }
end

--- Every book, most recently read first.
function Books:list(books_dir)
    local map = Availability:ensure(books_dir) or {}
    local entries = {}
    for checksum, file in pairs(map) do
        table.insert(entries, self:entryFor(file, checksum))
    end
    table.sort(entries, function(a, b)
        local ap = a.status == "reading" and 0 or 1
        local bp = b.status == "reading" and 0 or 1
        if ap ~= bp then return ap < bp end
        return a.title < b.title
    end)
    return entries
end

--- The book the hero card shows, plus whether it is a suggestion rather
--- than something already under way.
function Books:current(entries)
    local best
    for _, entry in ipairs(entries) do
        if entry.status == "reading" and entry.percent then
            if not best or entry.percent > best.percent then best = entry end
        end
    end
    if best then return best, false end
    return entries[1], true
end

--- `New`, `42%` or `Finished` — the tag in the cover's top-right corner.
function Books:progressTag(entry)
    if entry.status == "complete" then return "Finished" end
    if entry.status == "new" or not entry.percent then return "New" end
    return string.format("%d%%", math.floor(entry.percent * 100 + 0.5))
end

return Books
