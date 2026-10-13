--[[--
The server reading positions are shared through.

Three kinds speak the same KOReader sync protocol and differ only in where
they live and how they sign in: CWA's built-in one (the CWA login, sent as
basic auth), KOReader's free public server, or any other compatible server
(a username and an MD5 key in `x-auth-*` headers, the way KOReader's own
sync plugin does it). "off" keeps positions on the device.
--]]--

local Settings = require("settings")
local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")

local SyncServer = {
    PUBLIC = "https://sync.koreader.rocks",
    KINDS = { "cwa", "public", "custom", "off" },
}

--- Which server, at what address, signing in how. `kind` is "off" when
--- positions stay on the device, or when the chosen server lacks a login.
function SyncServer.current()
    local kind = Settings:get("sync_service")
    if kind == "cwa" then
        local server = Settings:get("server"):gsub("/+$", "")
        local user, password = require("catalog").credentials()
        if server == "" or not user then return { kind = "off" } end
        return { kind = "cwa", url = server .. "/kosync", username = user, password = password }
    end
    if kind == "public" or kind == "custom" then
        local url = kind == "public" and SyncServer.PUBLIC or Settings:get("sync_url")
        local user, key = Settings:get("sync_username"), Settings:get("sync_userkey")
        if url == "" or user == "" or not key then return { kind = "off", wanted = kind } end
        return { kind = kind, url = url:gsub("/+$", ""), username = user, userkey = key }
    end
    return { kind = "off" }
end

function SyncServer.enabled()
    return SyncServer.current().kind ~= "off"
end

local function base64(data)
    return (require("ffi/sha2").bin_to_base64(data))
end

--- One request against `server` (as `current()` gives it). Returns the HTTP
--- code and the decoded body, or nil and an error.
function SyncServer.request(server, method, path, payload, timeout)
    local headers = {
        ["Accept"] = "application/vnd.koreader.v1+json",
        ["Accept-Encoding"] = "identity",
    }
    if server.password then
        headers["Authorization"] = "Basic " .. base64(server.username .. ":" .. server.password)
    elseif server.userkey then
        headers["x-auth-user"] = server.username
        headers["x-auth-key"] = server.userkey
    end
    local body = payload and rapidjson.encode(payload) or nil
    if body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end
    local sink = {}
    socketutil:set_timeout(timeout or 5, timeout and timeout * 2 or 10)
    local code, _headers, status = socket.skip(1, http.request{
        url = server.url .. path,
        method = method,
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if type(code) ~= "number" then return nil, tostring(status or code) end
    local text = table.concat(sink)
    local ok, decoded = pcall(rapidjson.decode, text)
    return code, ok and decoded or nil
end

--- Where `document` was left off, as `{ percentage, progress, device,
--- device_id, timestamp }`, or nil when the server has nothing; nil and an
--- error when it cannot be asked.
function SyncServer.get(document, server)
    server = server or SyncServer.current()
    if server.kind == "off" then return nil, "sync is off" end
    local code, data = SyncServer.request(server, "GET", "/syncs/progress/" .. document)
    -- some servers answer an unknown document with 404 rather than an empty record
    if code == 404 then return nil end
    if code ~= 200 then return nil, code and ("HTTP " .. code) or data end
    if type(data) ~= "table" or type(data.percentage) ~= "number" then return nil end
    local function str(v) return type(v) == "string" and v or nil end
    return {
        percentage = data.percentage,
        progress = type(data.progress) == "number" and tostring(data.progress) or str(data.progress),
        device = str(data.device),
        device_id = str(data.device_id),
        timestamp = type(data.timestamp) == "number" and data.timestamp or nil,
    }
end

--- Tell the server where `document` is now, as this device.
function SyncServer.put(document, record, server)
    server = server or SyncServer.current()
    if server.kind == "off" then return false, "sync is off" end
    local Device = require("device")
    local code, err = SyncServer.request(server, "PUT", "/syncs/progress", {
        document = document,
        progress = record.progress,
        percentage = record.percentage,
        device = Device.model or "Nightstand",
        device_id = G_reader_settings and G_reader_settings:readSetting("device_id") or "nightstand",
    })
    if code == 200 or code == 202 then return true end
    return false, code and ("HTTP " .. code) or err
end

--- Whether the sync server answers at all, asked with a short timeout and
--- remembered for a while, so a server that is switched off costs one short
--- wait rather than one per book or per page turn.
function SyncServer.reachable(server)
    server = server or SyncServer.current()
    if server.kind == "off" then return false end
    local cache = SyncServer.reach
    -- an answer counts for a minute, silence for five: a server switched off
    -- for the evening is not knocked on every half minute
    if cache and cache.url == server.url and os.time() - cache.at < (cache.ok and 60 or 300) then
        return cache.ok
    end
    local code = SyncServer.request(server, "GET", "/users/auth", nil, 3)
    local ok = type(code) == "number" and code < 500
    SyncServer.reach = { url = server.url, at = os.time(), ok = ok }
    return ok
end

local function keyFor(password)
    return require("ffi/sha2").md5(password)
end

--- Check a username and password against a KOReader-protocol server
--- (public or custom). Returns ok, err.
function SyncServer.signIn(url, username, password)
    local server = { url = url:gsub("/+$", ""), username = username, userkey = keyFor(password) }
    local code, err = SyncServer.request(server, "GET", "/users/auth", nil, 10)
    if code == 200 then return true, server.userkey end
    if code == 401 then return false, "wrong username or password" end
    return false, code and ("HTTP " .. code) or err
end

--- Create an account on a KOReader-protocol server. Returns ok, err.
function SyncServer.register(url, username, password)
    local server = { url = url:gsub("/+$", "") }
    local code, data = SyncServer.request(server, "POST", "/users/create",
                                          { username = username, password = keyFor(password) }, 10)
    if code == 201 then return true, keyFor(password) end
    if code == 402 then return false, "that username is taken" end
    return false, code and (type(data) == "table" and data.message or ("HTTP " .. code)) or data
end

return SyncServer
