--[[--
Stand-ins for the two servers Nightstand talks to.

All network traffic goes through Catalog:get / Catalog:fetchTo (CWA) and
Hardcover:post (Hardcover), so replacing those three is enough to run every
code path offline and deterministically.
--]]--

local Fakes = {}

local function esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
                             :gsub('"', "&quot;"):gsub("'", "&#39;"))
end

--- One OPDS acquisition entry, shaped like CWA's.
function Fakes.entry(b)
    local parts = { "<entry>", "<title>" .. esc(b.title) .. "</title>" }
    if b.uuid then table.insert(parts, "<id>urn:uuid:" .. b.uuid .. "</id>") end
    table.insert(parts, "<updated>" .. (b.updated or "2026-09-16T14:03:09+00:00") .. "</updated>")
    for _, name in ipairs(b.authors or {}) do
        table.insert(parts, "<author><name>" .. esc(name) .. "</name></author>")
    end
    if b.published then table.insert(parts, "<published>" .. b.published .. "</published>") end
    if b.language then table.insert(parts, "<dcterms:language>" .. b.language .. "</dcterms:language>") end
    for _, g in ipairs(b.genres or {}) do
        table.insert(parts, string.format('<category scheme="x" term="%s" label="%s"/>', esc(g), esc(g)))
    end
    if b.summary then table.insert(parts, "<summary>" .. esc(b.summary) .. "</summary>") end
    table.insert(parts, string.format('<link type="image/jpeg" href="/opds/cover/%d" rel="http://opds-spec.org/image"/>', b.id))
    if not b.no_download then
        table.insert(parts, string.format(
            '<link rel="http://opds-spec.org/acquisition" href="/opds/download/%d/epub/" length="%d" type="application/epub+zip"/>',
            b.id, b.size or 1000))
    end
    table.insert(parts, "</entry>")
    return table.concat(parts, "\n")
end

function Fakes.feed(entries, next_href)
    local parts = { '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">',
                    '<link rel="self" href="/x"/>' }
    if next_href then
        table.insert(parts, string.format('<link rel="next" href="%s"/>', next_href))
    end
    for _, e in ipairs(entries) do table.insert(parts, e) end
    table.insert(parts, "</feed>")
    return table.concat(parts, "\n")
end

--- A navigation feed of subsections (CWA's series index).
function Fakes.nav(items)
    local entries = {}
    for _, item in ipairs(items) do
        table.insert(entries, string.format(
            '<entry><title>%s</title><link rel="subsection" href="%s"/></entry>',
            esc(item.title), item.href))
    end
    return Fakes.feed(entries)
end

--- A whole CWA server from a list of book descriptions:
--- { id, title, authors, series = {name, index}, read = bool, ... }.
--- `opts.page_size` splits the flat feed into linked pages like CWA does.
function Fakes.library(books, opts)
    opts = opts or {}
    for _, b in ipairs(books) do
        b.uuid = b.uuid or string.format("%08x-0000-4000-8000-%012x", b.id, b.id)
    end
    local routes = {}
    local size = opts.page_size or 60
    local pages = math.max(1, math.ceil(#books / size))
    for page = 1, pages do
        local entries = {}
        for i = (page - 1) * size + 1, math.min(#books, page * size) do
            table.insert(entries, Fakes.entry(books[i]))
        end
        local path = page == 1 and "/opds/books/letter/00" or ("/opds/books/letter/00?offset=" .. (page - 1) * size)
        local next_href = page < pages and ("/opds/books/letter/00?offset=" .. page * size) or nil
        routes[path] = Fakes.feed(entries, next_href)
    end

    -- newest first, by id descending unless the book says otherwise
    local by_added = {}
    for _, b in ipairs(books) do table.insert(by_added, b) end
    table.sort(by_added, function(a, b) return (a.added or a.id) > (b.added or b.id) end)
    local new = {}
    for _, b in ipairs(by_added) do table.insert(new, Fakes.entry(b)) end
    routes["/opds/new"] = Fakes.feed(new)

    local read = {}
    for _, b in ipairs(books) do if b.read then table.insert(read, Fakes.entry(b)) end end
    routes["/opds/readbooks"] = Fakes.feed(read)

    local series, order = {}, {}
    for _, b in ipairs(books) do
        if b.series then
            local s = series[b.series[1]]
            if not s then
                s = { name = b.series[1], books = {}, id = #order + 1 }
                series[b.series[1]] = s
                table.insert(order, s)
            end
            table.insert(s.books, b)
        end
    end
    local nav = {}
    for _, s in ipairs(order) do
        table.sort(s.books, function(a, b) return a.series[2] < b.series[2] end)
        local entries = {}
        for _, b in ipairs(s.books) do table.insert(entries, Fakes.entry(b)) end
        routes["/opds/series/" .. s.id] = Fakes.feed(entries)
        table.insert(nav, { title = s.name, href = "/opds/series/" .. s.id })
    end
    routes["/opds/series/letter/00"] = Fakes.nav(nav)

    for _, b in ipairs(books) do
        if b.uuid then
            routes["/ajax/book/" .. b.uuid] = string.format(
                '{"title": "x", "series": null, "series_index": %s}',
                b.series and tostring(b.series[2]) or "1.0")
        end
        routes["/opds/cover/" .. b.id] = Fakes.png()
        routes["/opds/download/" .. b.id .. "/epub/"] = "EPUBDATA-" .. b.id
    end
    return routes
end

--- Bytes of a small valid PNG, made once, so cover paths render real images.
function Fakes.png()
    if Fakes._png then return Fakes._png end
    local Blitbuffer = require("ffi/blitbuffer")
    local path = os.tmpname()
    local bb = Blitbuffer.new(60, 90, Blitbuffer.TYPE_BBRGB24)
    bb:fill(Blitbuffer.COLOR_GRAY)
    bb:writePNG(path)
    bb:free()
    local f = io.open(path, "rb")
    Fakes._png = f:read("*a")
    f:close()
    os.remove(path)
    return Fakes._png
end

--- Point Catalog at a route table. Returns the call log.
function Fakes.cwa(routes)
    local Catalog = require("catalog")
    local calls = {}
    Catalog.get = function(_, path)
        table.insert(calls, path)
        local body = routes[path]
        if type(body) == "function" then return body(path) end
        if body == nil then return nil, "404" end
        return body
    end
    Catalog.fetchTo = function(_, path, dest)
        table.insert(calls, path)
        local body = routes[path]
        if not body then return false, "404" end
        local f = assert(io.open(dest, "wb"))
        f:write(body)
        f:close()
        return true
    end
    return calls
end

--- A Hardcover server: device flow, rotating refresh tokens, replay
--- detection and `me`. `opts.pending` polls before approval, `opts.deny`.
function Fakes.hardcover(opts)
    opts = opts or {}
    local server = { log = {}, polls = 0, gen = 0, spent = {}, replayed = false, opts = opts,
                     online = true, me = opts.me or { { id = 7, username = "reader" } } }
    Fakes.hardcover_rebind(server)
    return server
end

--- Attach an existing fake server to a freshly loaded hardcover module.
function Fakes.hardcover_rebind(server)
    local opts = server.opts
    local Hardcover = require("hardcover")
    local rapidjson = require("rapidjson")

    local function issue()
        server.gen = server.gen + 1
        if server.refresh then server.spent[server.refresh] = true end
        server.access = "hc_at_" .. server.gen
        server.refresh = "hc_rt_" .. server.gen
        return 200, { access_token = server.access, refresh_token = server.refresh,
                      expires_in = opts.ttl or 604800 }
    end

    local function form(body)
        local out = {}
        for k, v in body:gmatch("([^&=]+)=([^&]*)") do
            out[k] = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        end
        return out
    end

    Hardcover.post = function(_, path, body, _type, token)
        table.insert(server.log, { path = path, token = token })
        if not server.online then return nil, nil end
        if path == "/oauth2/device" then
            server.polls = 0
            return 200, { device_code = "dev", user_code = "ABCD-1234",
                          verification_uri = "https://hardcover.app/link",
                          verification_uri_complete = "https://hardcover.app/link?code=ABCD-1234",
                          expires_in = 900, interval = opts.interval or 5 }
        elseif path == "/oauth2/token" then
            local f = form(body)
            if f.grant_type:match("device_code$") then
                server.polls = server.polls + 1
                if opts.deny then return 400, { error = "access_denied" } end
                if opts.slow_down and server.polls == 1 then return 400, { error = "slow_down" } end
                if server.polls <= (opts.pending or 0) then return 400, { error = "authorization_pending" } end
                return issue()
            end
            if server.spent[f.refresh_token] then
                server.replayed = true
                server.refresh, server.access = nil, nil
                return 400, { error = "invalid_grant" }
            end
            if f.refresh_token ~= server.refresh then return 400, { error = "invalid_grant" } end
            return issue()
        elseif path == "/oauth2/revoke" then
            server.revoked = form(body).token
            server.refresh, server.access = nil, nil
            return 200, {}
        elseif path == "/v1/graphql" then
            if not token or token ~= server.access then return 401, { error = "invalid_token" } end
            local q = rapidjson.decode(body)
            if q.query:match("me") then return 200, { data = { me = server.me } } end
            return 200, { data = {} }
        end
        return 404, nil
    end
end

--- A minimal but valid EPUB, so KOReader's real code paths can open it.
function Fakes.epub(path, title, author)
    local script = [[
import sys, zipfile
path, title, author = sys.argv[1:4]
opf = f"""<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{title}</dc:title><dc:creator>{author}</dc:creator>
<dc:identifier id="id">{title}</dc:identifier><dc:language>en</dc:language></metadata>
<manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>"""
with zipfile.ZipFile(path, "w") as z:
    z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
    z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    z.writestr("content.opf", opf)
    z.writestr("c.xhtml", f"<html xmlns='http://www.w3.org/1999/xhtml'><body><h1>{title}</h1><p>{title} by {author}. " + "Words. " * 400 + "</p></body></html>")
]]
    local dir = path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p '" .. dir .. "'")
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, "w")); f:write(script); f:close()
    local ok = os.execute(string.format("python3 %q %q %q %q", tmp, path, title, author))
    os.remove(tmp)
    assert(ok == 0 or ok == true, "could not build an epub at " .. path)
    return path
end

--- A fresh, empty books folder under the test profile.
function Fakes.booksDir(name)
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/books-" .. (name or "default")
    os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")
    return dir
end

return Fakes
