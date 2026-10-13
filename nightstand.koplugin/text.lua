--[[--
Small text helpers shared by the catalogue, the local library and Discover:
reading XML entities, comparing titles loosely, and finding a surname.
--]]--

local util = require("util")

local Text = {}

--- XML entities read back into plain characters, any code point included.
function Text.decode(str)
    if not str then return "" end
    str = str:gsub("&#[xX](%x+);", function(hex) return util.unicodeCodepointToUtf8(tonumber(hex, 16)) end)
    str = str:gsub("&#(%d+);", function(code) return util.unicodeCodepointToUtf8(tonumber(code)) end)
    return (str:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
               :gsub("&apos;", "'"):gsub("&amp;", "&"))
end

--- A title (or name) for loose comparison: lower case, words only.
function Text.norm(str)
    str = (str or ""):lower():gsub("&#39;", "'")
    return (str:gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The first author's last name, as written: "Brandon Sanderson, Someone" -> "Sanderson".
function Text.surname(authors)
    local first = (authors or ""):match("^[^,]+") or ""
    return first:match("(%S+)%s*$") or ""
end

return Text
