--[[--
Where to look a book up: a shop, a library catalogue, anything with a search
URL. Nightstand never sells anything; it hands the reader a link (as a QR
code, since most e-readers have no browser) and the phone does the rest.
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")
local Settings = require("settings")
local _ = require("gettext")
local T = require("ffi/util").template

local Vendors = {}

-- {title}, {author} and {query} (both together) are filled in and escaped.
Vendors.BUILT_IN = {
    { id = "kobo", name = "Kobo", url = "https://www.kobo.com/search?query={query}" },
    { id = "openlibrary", name = "Open Library", url = "https://openlibrary.org/search?q={query}" },
    { id = "worldcat", name = "WorldCat (libraries)", url = "https://search.worldcat.org/search?q={query}" },
}

local function escape(str)
    return ((str or ""):gsub("[^%w%-%._~ ]", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+"))
end

function Vendors.all()
    local list = {}
    for _index, v in ipairs(Vendors.BUILT_IN) do table.insert(list, v) end
    for _index, v in ipairs(Settings:get("custom_vendors") or {}) do table.insert(list, v) end
    return list
end

function Vendors.current()
    local id = Settings:get("vendor") or "kobo"
    for _index, v in ipairs(Vendors.all()) do
        if v.id == id then return v end
    end
    return Vendors.BUILT_IN[1]
end

function Vendors.urlFor(vendor, book)
    local first_author = (book.author or ""):match("^[^,]+") or ""
    local query = book.title .. (first_author ~= "" and (" " .. first_author) or "")
    -- functions, not strings: an escaped "%27" would read as a capture index
    local values = { query = escape(query), title = escape(book.title), author = escape(first_author) }
    return (vendor.url:gsub("{(%a+)}", function(key) return values[key] end))
end

--- Add a vendor from a name and a URL template. Returns ok, err.
function Vendors.add(name, url)
    name, url = (name or ""):gsub("^%s+", ""):gsub("%s+$", ""), (url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return false, _("A name is needed.") end
    if not url:match("^https?://") then return false, _("The address must start with http:// or https://") end
    if not url:match("{query}") and not url:match("{title}") then
        return false, _("Put {query} (or {title} and {author}) where the search words go.")
    end
    local custom = Settings:get("custom_vendors") or {}
    local id = "custom-" .. os.time()
    table.insert(custom, { id = id, name = name, url = url })
    Settings:set("custom_vendors", custom)
    Settings:set("vendor", id)
    return true
end

--- Show the lookup for a book: a QR code everywhere, and on devices that
--- can open links, a button for that as well.
function Vendors.show(book)
    local vendor = Vendors.current()
    local url = Vendors.urlFor(vendor, book)
    local QRMessage = require("ui/widget/qrmessage")
    local Screen = Device.screen
    local size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.6)
    if Device:canOpenLink() then
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        dialog = ButtonDialog:new{
            title = T(_("Find \"%1\" on %2"), book.title, vendor.name),
            buttons = {
                {{ text = _("Open in browser"), callback = function()
                    UIManager:close(dialog)
                    Device:openLink(url)
                end }},
                {{ text = _("Show QR code"), callback = function()
                    UIManager:close(dialog)
                    UIManager:show(QRMessage:new{ text = url, width = size, height = size })
                end }},
            },
        }
        UIManager:show(dialog)
    else
        UIManager:show(QRMessage:new{ text = url, width = size, height = size })
    end
    return url
end

return Vendors
