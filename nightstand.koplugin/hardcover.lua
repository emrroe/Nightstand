--[[--
Hardcover account link and API client.

Sign-in is OAuth's Device Authorization Grant: Nightstand is a public client
(the client id ships with the plugin, there is no secret), the reader shows a
code, and the user approves it on a phone. Each device links on its own, so no
two devices ever share a refresh token.

Refresh tokens rotate on every use and a replayed one revokes the whole chain,
so a new pair is written to disk before anything else touches it.
--]]--

local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local Settings = require("settings")

local Hardcover = {
    -- Public by design: anyone can read it out of the plugin.
    CLIENT_ID = "",
    API = "https://api.hardcover.app",
    SCOPE = "read:me:content read:library read:vibes read:catalog:data write:library",
}

-- Refresh this long before the access token's stated expiry.
local EXPIRY_MARGIN = 3600

function Hardcover:clientId()
    local override = Settings:get("hardcover_client_id")
    if override and override ~= "" then return override end
    return self.CLIENT_ID
end

--- Developer override so the flow can run against a local mock.
function Hardcover:api()
    local override = Settings:get("hardcover_api")
    if override and override ~= "" then return (override:gsub("/+$", "")) end
    return self.API
end

function Hardcover:isAvailable()
    return self:clientId() ~= ""
end

function Hardcover:isLinked()
    local account = Settings:get("hardcover")
    return account ~= nil and account.refresh_token ~= nil
end

function Hardcover:username()
    local account = Settings:get("hardcover")
    return account and account.username
end

local function encodeForm(fields)
    local parts = {}
    for key, value in pairs(fields) do
        local escaped = tostring(value):gsub("[^%w%-%._~]", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        table.insert(parts, key .. "=" .. escaped)
    end
    return table.concat(parts, "&")
end

--- One POST. Returns status code and decoded JSON body (or nil).
function Hardcover:post(path, body, content_type, token)
    local sink = {}
    local headers = {
        ["Content-Type"] = content_type,
        ["Content-Length"] = tostring(#body),
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "identity",
        ["User-Agent"] = "Nightstand (KOReader plugin)",
    }
    if token then headers["Authorization"] = "Bearer " .. token end

    socketutil:set_timeout(10, 30)
    local code, _headers, status = socket.skip(1, http.request{
        url = self:api() .. path,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    local raw = table.concat(sink)
    local ok, data = pcall(rapidjson.decode, raw)
    if not ok or type(data) ~= "table" then data = nil end
    if type(code) ~= "number" then
        logger.warn("Nightstand: Hardcover request failed:", path, status or code)
        return nil, nil
    end
    return code, data
end

function Hardcover:postForm(path, fields)
    return self:post(path, encodeForm(fields), "application/x-www-form-urlencoded")
end

local function store(token)
    local previous = Settings:get("hardcover") or {}
    Settings:set("hardcover", {
        access_token = token.access_token,
        refresh_token = token.refresh_token or previous.refresh_token,
        expires_at = os.time() + (tonumber(token.expires_in) or 604800),
        username = previous.username,
    })
end

--- Step 1: ask for a device code. Returns the response table or nil, err.
function Hardcover:startLink()
    if not self:isAvailable() then return nil, "no client id" end
    local code, data = self:postForm("/oauth2/device", {
        client_id = self:clientId(),
        scope = self.SCOPE,
    })
    if code ~= 200 or not data or not data.device_code then
        return nil, data and data.error or "could not reach Hardcover"
    end
    return data
end

--- Step 3: one poll. Returns "linked", "pending", "slow_down", or "failed", err.
function Hardcover:poll(device_code)
    local code, data = self:postForm("/oauth2/token", {
        grant_type = "urn:ietf:params:oauth:grant-type:device_code",
        device_code = device_code,
        client_id = self:clientId(),
    })
    if code == 200 and data and data.access_token then
        store(data)
        return "linked"
    end
    if code == nil then return "pending" end -- network blip: try again next tick
    local err = data and data.error
    if err == "authorization_pending" then return "pending" end
    if err == "slow_down" then return "slow_down" end
    return "failed", err or ("HTTP " .. tostring(code))
end

--- Swap the refresh token for a new pair. The new pair is on disk before
--- this returns, so a crash afterwards cannot leave a spent token behind.
function Hardcover:refresh()
    local account = Settings:get("hardcover")
    if not account or not account.refresh_token then return false end
    local code, data = self:postForm("/oauth2/token", {
        grant_type = "refresh_token",
        refresh_token = account.refresh_token,
        client_id = self:clientId(),
    })
    if code == 200 and data and data.access_token then
        store(data)
        return true
    end
    if code == 400 or code == 401 then
        -- invalid_grant: the chain was revoked or has expired; only a new link helps
        logger.warn("Nightstand: Hardcover refresh rejected:", data and data.error)
        self:forget()
    end
    return false
end

function Hardcover:accessToken()
    local account = Settings:get("hardcover")
    if not account then return nil end
    if not account.access_token or (account.expires_at or 0) - EXPIRY_MARGIN < os.time() then
        if not self:refresh() then return nil end
        account = Settings:get("hardcover")
    end
    return account.access_token
end

--- Run a GraphQL query. Returns the `data` table or nil, err.
function Hardcover:query(query, variables)
    local token = self:accessToken()
    if not token then return nil, "not linked" end
    local body = rapidjson.encode({ query = query, variables = variables or rapidjson.null })
    local code, data = self:post("/v1/graphql", body, "application/json", token)
    if code == 401 and self:refresh() then
        code, data = self:post("/v1/graphql", body, "application/json", self:accessToken())
    end
    if code ~= 200 or not data then return nil, "HTTP " .. tostring(code) end
    if data.errors then
        local first = data.errors[1]
        return nil, first and first.message or "query failed"
    end
    return data.data
end

--- Fetch and remember the linked account's username.
function Hardcover:fetchMe()
    local data, err = self:query("{ me { id username } }")
    if not data then return nil, err end
    -- `me` comes back as a one-element array
    local me = data.me and (data.me[1] or data.me)
    if not me or not me.username then return nil, "no profile" end
    local account = Settings:get("hardcover")
    account.username = me.username
    account.user_id = me.id
    Settings:set("hardcover", account)
    return me.username
end

function Hardcover:forget()
    Settings:delete("hardcover")
end

--- Revoke on Hardcover's side too, then forget locally whatever the answer.
function Hardcover:unlink()
    local account = Settings:get("hardcover")
    if account and account.refresh_token then
        self:postForm("/oauth2/revoke", {
            token = account.refresh_token,
            token_type_hint = "refresh_token",
            client_id = self:clientId(),
        })
    end
    self:forget()
end

return Hardcover
