local T = require("t")

local function clear(keys)
    for _, key in ipairs(keys) do require("settings"):delete(key) end
end
local SYNC_KEYS = { "server", "username", "password", "sync_service", "sync_url", "sync_username",
                    "sync_userkey", "sync_plugins_retired" }

T.describe("which sync server", function()
    T.it("CWA by default when a server is set, signing in with the CWA login", function()
        local Settings, SyncServer = require("settings"), require("syncserver")
        clear(SYNC_KEYS)
        T.eq(SyncServer.current().kind, "off", "no server, no sync")
        Settings:set("server", "https://books.example/")
        Settings:set("username", "reader")
        Settings:set("password", "secret")
        local s = SyncServer.current()
        T.eq(s.kind, "cwa")
        T.eq(s.url, "https://books.example/kosync")
        T.eq(s.password, "secret")
    end)
    T.it("the public server and others sign in with a key, and only once signed in", function()
        local Settings, SyncServer = require("settings"), require("syncserver")
        clear(SYNC_KEYS)
        Settings:set("sync_service", "public")
        T.eq(SyncServer.current().kind, "off", "not signed in yet")
        Settings:set("sync_username", "me")
        Settings:set("sync_userkey", "abc")
        local s = SyncServer.current()
        T.eq(s.kind, "public")
        T.eq(s.url, SyncServer.PUBLIC)
        Settings:set("sync_service", "custom")
        Settings:set("sync_url", "https://sync.example/")
        T.eq(SyncServer.current().url, "https://sync.example")
        Settings:set("sync_service", "off")
        T.eq(SyncServer.current().kind, "off")
    end)
    T.it("sends basic auth to CWA and x-auth headers to the others", function()
        local SyncServer = require("syncserver")
        local http = require("socket.http")
        local real = http.request
        local seen
        http.request = function(req)
            seen = req
            req.sink('{"percentage": 0.5, "progress": "/x", "device": "nova2", "device_id": "n", "timestamp": 5}')
            return 1, 200, {}, "200 OK"
        end
        local rec = SyncServer.get("doc", { kind = "cwa", url = "https://b/kosync", username = "u", password = "p" })
        T.eq(seen.url, "https://b/kosync/syncs/progress/doc")
        T.eq(seen.headers["Authorization"], "Basic dTpw")
        T.eq(rec.percentage, 0.5)
        SyncServer.get("doc", { kind = "public", url = "https://s", username = "u", userkey = "k" })
        T.eq(seen.headers["x-auth-user"], "u")
        T.eq(seen.headers["x-auth-key"], "k")
        T.eq(seen.headers["Authorization"], nil)
        http.request = real
    end)
    T.it("a document the server has never seen is no position, not an error", function()
        local SyncServer = require("syncserver")
        local http = require("socket.http")
        local real = http.request
        local code, body = 404, '{"message": "Document not found"}'
        http.request = function(req) req.sink(body) return 1, code, {}, "x" end
        local server = { kind = "cwa", url = "https://b/kosync", username = "u", password = "p" }
        local rec, err = SyncServer.get("doc", server)
        T.eq(rec, nil)
        T.eq(err, nil, "404: nothing there yet")
        code, body = 200, "{}"
        rec, err = SyncServer.get("doc", server)
        T.eq(rec, nil)
        T.eq(err, nil, "an empty record, as KOReader's own server answers")
        code = 500
        T.eq(select(2, SyncServer.get("doc", server)), "HTTP 500", "a broken server is still an error")
        http.request = real
    end)
    T.it("signing up and in report what went wrong", function()
        local SyncServer = require("syncserver")
        local http = require("socket.http")
        local real = http.request
        local code = 402
        http.request = function(req) req.sink("{}") return 1, code, {}, "x" end
        T.eq(select(2, SyncServer.register("https://s", "u", "p")), "that username is taken")
        code = 201
        local ok, key = SyncServer.register("https://s", "u", "p")
        T.ok(ok)
        T.eq(key, require("ffi/sha2").md5("p"), "the key is the password's MD5, as KOReader's sync uses")
        code = 401
        T.eq(select(2, SyncServer.signIn("https://s", "u", "bad")), "wrong username or password")
        http.request = real
    end)
end)

T.describe("first start", function()
    local function reset()
        clear(SYNC_KEYS)
        require("setup").ran = nil
        G_reader_settings:delSetting("cwasync")
        G_reader_settings:delSetting("kosync")
        G_reader_settings:delSetting("plugins_disabled")
    end
    T.it("takes the CWA server and login over from the CWA sync plugin, and syncs through CWA", function()
        local Settings, Setup = require("settings"), require("setup")
        reset()
        G_reader_settings:saveSetting("cwasync", { server = "https://books.example", username = "reader",
                                                   password = "secret", auto_sync = true })
        Setup.run()
        T.eq(Settings:get("server"), "https://books.example")
        T.eq(Settings:get("username"), "reader")
        T.eq(Settings:get("sync_service"), "cwa")
        local disabled = G_reader_settings:readSetting("plugins_disabled")
        T.ok(disabled.cwasync and disabled.kosync, "both other sync plugins are off")
    end)
    T.it("keeps a KOReader sync account, on the public or its own server", function()
        local Settings, Setup = require("settings"), require("setup")
        reset()
        G_reader_settings:saveSetting("kosync", { username = "me", userkey = "k" })
        Setup.run()
        T.eq(Settings:get("sync_service"), "public")
        T.eq(Settings:get("sync_username"), "me")
        T.eq(Setup.run(), {}, "once per start")
        reset()
        G_reader_settings:saveSetting("kosync", { username = "me", userkey = "k", custom_server = "https://s" })
        Setup.run()
        T.eq(Settings:get("sync_service"), "custom")
        T.eq(Settings:get("sync_url"), "https://s")
    end)
    T.it("switches the other sync plugins off only once, and not at all without sync", function()
        local Settings, Setup = require("settings"), require("setup")
        reset()
        Setup.run()
        T.eq(Settings:get("sync_service"), "off")
        T.eq(G_reader_settings:readSetting("plugins_disabled"), nil, "nothing to replace")
        reset()
        Settings:set("server", "https://books.example")
        Settings:set("username", "u")
        Settings:set("password", "p")
        Setup.run()
        G_reader_settings:saveSetting("plugins_disabled", {})
        Setup.ran = nil
        Setup.run()
        T.eq(G_reader_settings:readSetting("plugins_disabled").kosync, nil, "turned back on stays on")
    end)
    T.it("a new reader who chooses a server syncs through it, and the old plugins step aside", function()
        local Settings = require("settings")
        local UIManager = require("ui/uimanager")
        reset()
        Settings:delete("books_dir")
        Settings:delete("welcomed")
        local Nightstand = require("main")
        local shown = {}
        local show, nextTick = UIManager.show, UIManager.nextTick
        UIManager.show = function(_, w) table.insert(shown, w) end
        UIManager.nextTick = function(_, f) f() end
        local ok, err = xpcall(function()
            local ui = { menu = { registerToMainMenu = function() end },
                         registerPostInitCallback = function(_, f) f() end }
            Nightstand:new{ ui = ui }
            T.eq(Settings:get("sync_service"), "off", "nothing to sync with yet")
            T.eq(Settings:get("sync_plugins_retired"), nil, "nothing replaces them yet")
            local welcome = shown[#shown]
            T.eq(welcome.name, "nightstand_welcome")
            welcome.refresh = function() end
            welcome:chooseServer()
            local dialog = shown[#shown]
            dialog.getFields = function() return { "https://books.example", "reader", "secret", "/tmp" } end
            dialog.onShowKeyboard = function() end
            dialog.buttons[1][2].callback()
            T.eq(welcome.step, "hardcover", "on to the next step")
        end, debug.traceback)
        UIManager.show, UIManager.nextTick = show, nextTick
        T.ok(ok, tostring(err))
        T.eq(Settings:get("sync_service"), "cwa")
        T.ok(require("syncserver").enabled())
        local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
        T.ok(disabled.cwasync and disabled.kosync, "both other sync plugins are off")
    end)
    T.it("an old sync plugin still running this session keeps the job alone", function()
        local Settings, Setup = require("settings"), require("setup")
        T.ok(Setup.otherSyncRunning({ cwasync = {} }))
        T.ok(not Setup.otherSyncRunning({}))
        G_reader_settings:saveSetting("kosync", { userkey = "k" })
        T.ok(Setup.otherSyncRunning({ kosync = {} }))
        G_reader_settings:delSetting("kosync")
    end)
end)

T.describe("the plugin list", function()
    T.it("lists KOReader's plugins without Nightstand, and switches them", function()
        local PluginsScreen = require("pluginsscreen")
        local list = PluginsScreen.list()
        T.ok(#list > 5, "KOReader's own plugins are there")
        for _, p in ipairs(list) do T.ok(p.name ~= "nightstand") end
        local name = list[1].name
        local was = PluginsScreen.isOn(name)
        PluginsScreen.set(name, not was)
        T.eq(PluginsScreen.isOn(name), not was)
        PluginsScreen.set(name, was)
        T.eq(PluginsScreen.isOn(name), was)
    end)
end)

T.finish()
