--[[--
Updates Nightstand from its GitHub releases.

A release carries the plugin as `nightstand.koplugin.zip`, a single
`nightstand.koplugin/` folder. Installing unpacks it next to the running
copy, checks it is whole, then swaps the two folders -- putting the old one
back if anything fails -- so a half-finished update never replaces a working
plugin. KOReader then restarts to load it.
--]]--

local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")

local Updater = {
    REPO = "emrroe/Nightstand",
    ASSET = "nightstand.koplugin.zip",
    FOLDER = "nightstand.koplugin",
}

local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")

function Updater.currentVersion()
    local ok, meta = pcall(dofile, PLUGIN_DIR .. "/_meta.lua")
    return ok and meta.version or "0"
end

--- A copy run from a git checkout (or a link to one) is updated with git,
--- never by overwriting it.
function Updater.isDevelopmentCopy()
    return lfs.symlinkattributes(PLUGIN_DIR, "mode") == "link"
        or lfs.attributes(PLUGIN_DIR .. "/../.git") ~= nil
end

--- "0.2.0-alpha.3" as numbers to compare: a release beats its pre-releases,
--- and alpha < beta < rc.
function Updater.parse(version)
    local core, pre = tostring(version):gsub("^v", ""):match("^([%d%.]+)%-?(.*)$")
    local out = {}
    for n in (core or "0"):gmatch("%d+") do table.insert(out, tonumber(n)) end
    for i = #out + 1, 3 do out[i] = 0 end
    local stage, n = pre:match("^(%a+)%.?(%d*)$")
    local rank = { alpha = 1, beta = 2, rc = 3 }
    out[4] = pre == "" and 4 or (rank[stage] or 0)
    out[5] = tonumber(n) or 0
    return out
end

function Updater.newer(a, b)
    local x, y = Updater.parse(a), Updater.parse(b)
    for i = 1, 5 do
        if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return false
end

--- GET `url`, following GitHub's redirects to its file host. Returns the
--- body, or nil and an error. Bodies of the redirects themselves are dropped.
local function get(url, accept)
    for _hop = 1, 5 do
        local body = {}
        socketutil:set_timeout(15, 60)
        local code, headers, status = socket.skip(1, http.request{
            url = url,
            method = "GET",
            headers = { ["User-Agent"] = "Nightstand", ["Accept"] = accept or "*/*" },
            sink = ltn12.sink.table(body),
            redirect = false,
        })
        socketutil:reset_timeout()
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            url = headers and (headers.location or headers.Location)
            if not url then return nil, "redirect without a location" end
        elseif code == 200 then
            return table.concat(body)
        else
            return nil, tostring(status or code)
        end
    end
    return nil, "too many redirects"
end
Updater.fetch = get

--- The newest release that carries the plugin: `{ version, notes, url }`.
--- Pre-releases count while Nightstand is in alpha.
function Updater.latest()
    local body, err = Updater.fetch("https://api.github.com/repos/" .. Updater.REPO .. "/releases?per_page=10",
                          "application/vnd.github+json")
    if not body then return nil, err end
    local parsed, list = pcall(rapidjson.decode, body)
    if not parsed or type(list) ~= "table" then return nil, "unreadable answer" end
    local best
    for _index, release in ipairs(list) do
        if release.draft ~= true and type(release.tag_name) == "string" then
            for _index2, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
                if asset.name == Updater.ASSET and type(asset.browser_download_url) == "string" then
                    local version = release.tag_name:gsub("^v", "")
                    if not best or Updater.newer(version, best.version) then
                        best = { version = version, url = asset.browser_download_url,
                                 notes = type(release.body) == "string" and release.body or "" }
                    end
                end
            end
        end
    end
    if not best then return nil, "no release found" end
    return best
end

--- Unpack `zip` into `dest`, which must not exist yet. Only a single
--- nightstand.koplugin/ folder holding _meta.lua and main.lua is accepted.
function Updater.unpack(zip, dest)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(zip) then return false, "not a zip file" end
    local prefix = Updater.FOLDER .. "/"
    local files, has = {}, {}
    for entry in reader:iterate() do
        if entry.path:sub(1, #prefix) ~= prefix or entry.path:find("%.%.") then
            reader:close()
            return false, "unexpected file in the update: " .. entry.path
        end
        if entry.mode == "file" then
            table.insert(files, entry.path)
            has[entry.path:sub(#prefix + 1)] = true
        end
    end
    if not (has["_meta.lua"] and has["main.lua"]) then
        reader:close()
        return false, "the update is incomplete"
    end
    for _index, path in ipairs(files) do
        local target = dest .. "/" .. path:sub(#prefix + 1)
        util.makePath(target:match("^(.*)/[^/]+$"))
        if not reader:extractToPath(path, target) then
            reader:close()
            return false, "could not unpack " .. path
        end
    end
    reader:close()
    return true
end

--- Download `release` and put it in place of the running copy.
function Updater.install(release)
    if Updater.isDevelopmentCopy() then return false, "this copy is a development checkout" end
    local zip = DataStorage:getDataDir() .. "/cache/nightstand-update.zip"
    util.makePath(DataStorage:getDataDir() .. "/cache")
    local data, err = Updater.fetch(release.url)
    if not data then return false, err end
    local file = io.open(zip, "wb")
    if not file then return false, "cannot write " .. zip end
    file:write(data)
    file:close()

    local parent = PLUGIN_DIR:match("^(.*)/[^/]+$")
    local staged, old = parent .. "/" .. Updater.FOLDER .. ".new", parent .. "/" .. Updater.FOLDER .. ".old"
    ffiUtil.purgeDir(staged)
    ffiUtil.purgeDir(old)
    local ok
    ok, err = Updater.unpack(zip, staged)
    os.remove(zip)
    if not ok then
        ffiUtil.purgeDir(staged)
        return false, err
    end
    if not os.rename(PLUGIN_DIR, old) then
        ffiUtil.purgeDir(staged)
        return false, "cannot move the current version aside"
    end
    if not os.rename(staged, PLUGIN_DIR) then
        os.rename(old, PLUGIN_DIR)
        ffiUtil.purgeDir(staged)
        return false, "cannot put the new version in place"
    end
    ffiUtil.purgeDir(old)
    logger.info("Nightstand: updated to", release.version)
    return true
end

return Updater
