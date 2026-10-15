--[[--
Nightstand: a home screen backed by a Calibre-Web-Automated library.

The server holds the shelf, the device holds a cache of it. Books that are
not on this device are marked; everything else is a normal KOReader file.

@module koplugin.Nightstand
--]]--
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local Dialogs = require("dialogs")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Availability = require("availability")
local Books = require("books")
local Catalog = require("catalog")
local CoverCache = require("covercache")
local Progress = require("progress")
local Background = require("background")
local Fetcher = require("fetcher")
local Net = require("net")
local Settings = require("settings")
local _ = require("gettext")
local T = require("ffi/util").template

local MENU_TEXT = _("Nightstand")

local Nightstand = WidgetContainer:extend{
    name = "nightstand",
    is_doc_only = false,
}

-- KOReader rebuilds the file manager on startup and again every time a book
-- closes. Showing the home screen on each of those is what makes it the home
-- rather than a screen you navigate to; the file browser stays underneath as
-- the way out.
local shown_home = nil
-- Open Nightstand was chosen in a book: Home follows once it has closed
local home_after_reader = false

local SYNC_PLUGIN_NAMES = { cwasync = _("CWA Progress Sync"), kosync = _("Progress sync") }

function Nightstand:init()
    self.ui.menu:registerToMainMenu(self)
    self:askRestartFor(require("setup").run())
    -- `name = "filemanager"` lives on the FileChooser, not on FileManager, so
    -- the absence of a document is what distinguishes the two hosts.
    if not self.ui.document and self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function() self:openAsHome() end)
    end
end

--- Sync just came on: the old sync plugins step aside.
function Nightstand:syncChanged()
    self:askRestartFor(require("setup").retireSyncPlugins())
end

function Nightstand:askRestartFor(retired)
    if #retired == 0 then return end
    local names = {}
    for i, name in ipairs(retired) do names[i] = SYNC_PLUGIN_NAMES[name] or name end
    UIManager:nextTick(function()
        UIManager:askForRestart(T(_("Nightstand now keeps reading positions in sync itself, so %1 has been switched off. Restart KOReader to finish."),
                                  table.concat(names, ", ")))
    end)
end

-- in the reader: the open book's position, shared through the sync server

function Nightstand:onReaderReady()
    if not self.ui.document or not require("syncserver").enabled() then return end
    -- an old sync plugin still running until the restart keeps the job alone
    if require("setup").otherSyncRunning(self.ui) then return end
    self.sync = require("syncengine").new(self.ui)
    self.sync:opened()
end

function Nightstand:onPageUpdate()
    if self.sync then self.sync:pageTurned() end
end

function Nightstand:onNetworkConnected()
    if self.sync then self.sync:connected() end
end

function Nightstand:onCloseDocument()
    if self.sync then self.sync:leaving() end
    Books:invalidate()
end

function Nightstand:onSuspend()
    if self.sync then self.sync:leaving() end
end

function Nightstand:onCloseWidget()
    if self.sync then self.sync:stop() end
end

--- Nightstand's own settings screen.
function Nightstand:openSettings()
    UIManager:show(require("settingsscreen"):new{ plugin = self }, "ui")
end

--- The Library tab; with `query`, only the books it matches.
function Nightstand:openLibrary(query)
    UIManager:show(require("libraryscreen"):new{ plugin = self, query = query }, "ui")
end

--- Discover fetches from Hardcover the first time, when online; after that
--- it shows what it has until the refresh button in Discover is used.
function Nightstand:openDiscover()
    local Discover = require("discover")
    local DiscoverScreen = require("discoverscreen")
    if not Discover:load() and Net.isOnline() then
        local ok, err = DiscoverScreen.fetch(Books:list(Settings:booksDir()))
        if not ok then
            Dialogs.note(T(_("Could not reach Hardcover.\n%1"), tostring(err)))
            return
        end
    end
    if not Discover:load() then
        Dialogs.note(DiscoverScreen.emptyMessage())
        return
    end
    UIManager:show(DiscoverScreen:new{ plugin = self }, "ui")
end

--- The home screen stays underneath; every other tab opens on top of it.
function Nightstand:openTab(id)
    if id == "library" then return self:openLibrary() end
    if id == "discover" then return self:openDiscover() end
    if id == "settings" then return self:openSettings() end
end

--- Everything else: KOReader's own menu, at its usual place.
function Nightstand:openKoreaderMenu()
    local menu = self.ui and self.ui.menu
    if menu then menu:onShowMenu() end
end

function Nightstand:openAsHome()
    local asked = home_after_reader
    home_after_reader = false
    if not (Settings:get("replace_file_browser") or asked) then return end
    local Welcome = require("welcomescreen")
    if Welcome.needed() then
        return UIManager:nextTick(function() UIManager:show(Welcome:new{ plugin = self }) end)
    end
    if Settings:booksDir() == "" then return end
    UIManager:nextTick(function()
        self:open()
        -- first run: fetch the library rather than greet the user with nothing
        if Catalog:count() == 0 and Settings:get("server") ~= "" and Net.isOnline() then
            self:refreshCatalogue()
            if shown_home then shown_home:reload() end
        end
    end)
end

function Nightstand:open()
    if Settings:booksDir() == "" then
        Dialogs.note(_("Set a books folder first, in Settings."))
        return
    end
    -- from a book: close it the way the reader's own Home button does, so
    -- where it stands and when it was read are saved before Home reads them
    if self.ui.document then
        home_after_reader = true
        return self.ui:onHome()
    end
    -- a Home left open underneath (the file browser was created over it)
    -- must not block a fresh one on top
    if shown_home then UIManager:close(shown_home) end
    shown_home = require("homescreen"):new{
        plugin = self,
        on_closed = function() shown_home = nil end,
    }
    UIManager:show(shown_home)
end

--- Coming back from sleep: positions may have moved on another device.
--- In a book the sync engine compares again; on Home the shelves' positions
--- refresh. Quietly skipped when offline; the next wake or refresh catches up.
function Nightstand:onResume()
    if self.sync then return self.sync:woke() end
    UIManager:scheduleIn(3, function()
        local home = shown_home
        if not (home and UIManager:isWidgetShown(home)) then return end
        -- "today 23:50" may be yesterday by now
        home:refresh()
        if not (Settings:get("refresh_on_wake") and Net.isOnline()) then return end
        local moving = {}
        for _index, entry in ipairs(home.entries) do
            if entry.on_device or entry.status == "reading" then table.insert(moving, entry) end
        end
        self:refreshInBackground(moving, true)
    end)
end

--- Pull the CWA catalogue (quick, shown as busy), then fetch series,
--- covers and reading positions in the background while the screens stay
--- usable.
function Nightstand:refreshCatalogue()
    local working = Dialogs.working(_("Refreshing catalogue…"))
    local entries, err = Catalog:refresh()
    UIManager:close(working)
    if not entries then
        Dialogs.note(T(_("Could not reach the server.\n%1"), tostring(err)))
        return
    end
    Availability:invalidate()
    Catalog:refreshSeries()
    self:refreshInBackground(Books:list(Settings:booksDir()))
end

local function redrawHome(final)
    if not (shown_home and UIManager:isWidgetShown(shown_home)) then return end
    if final then shown_home:reload() else shown_home:refresh() end
end

function Nightstand:refreshInBackground(shelf, positions_only)
    if not positions_only and Net.mayDownload() then
        local missing = {}
        for _index, entry in ipairs(shelf) do
            if not entry.on_device and entry.book_id and not CoverCache:hasRemote(entry.book_id) then
                table.insert(missing, entry)
            end
        end
        local function fetch(entry) return CoverCache:fetchRemote(entry.book_id, entry.cover_url) end
        Fetcher.start("covers", missing, fetch, {
            label = _("Covers"),
            -- the child cleared its own copy; it may have been painted coverless here
            on_arrive = function(entry, ok) if ok then CoverCache.misses["id:" .. entry.book_id] = nil end end,
            on_progress = function() redrawHome(false) end,
        })
    end
    -- a sync server that is switched off would cost a timeout per book
    if not require("syncserver").reachable() then return end
    Background.run(shelf, function(entry) Progress:refreshEntry(entry) end, {
        label = _("Positions"),
        redraw_every = 6,
        on_done = function() Progress:save() end,
    })
end

--- While background work runs, Home redraws as results arrive.
Background.on_progress = function(final) redrawHome(final) end

--- The CWA server, its login, and the folder books go to. `on_saved` runs
--- after Save (the welcome screen goes on from there).
function Nightstand:editServer(on_saved)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Calibre-Web-Automated server"),
        fields = {
            { description = _("Server address"), text = Settings:get("server"), hint = "https://books.example.org" },
            { description = _("Username"), text = Settings:get("username") },
            { description = _("Password"), text = Settings:get("password"), text_type = "password" },
            { description = _("Books folder on this device"), text = Settings:get("books_dir"),
              hint = "/mnt/onboard/Books" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local fields = dialog:getFields()
                local had_server = Settings:get("server") ~= ""
                -- the bare root, never a trailing slash: paths are added to it
                Settings:set("server", (fields[1] or ""):gsub("/+$", ""))
                Settings:set("username", fields[2] or "")
                Settings:set("password", fields[3] or "")
                local dir = (fields[4] or ""):gsub("/+$", "")
                -- a new server user without a folder gets one next to KOReader's home
                if dir == "" and fields[1] ~= "" then
                    local home = G_reader_settings:readSetting("home_dir") or require("device").home_dir
                    dir = home and (home .. "/Books") or ""
                    if dir ~= "" then require("util").makePath(dir) end
                end
                Settings:set("books_dir", dir)
                if not had_server and Settings:get("server") ~= "" then require("setup").serverAdded() end
                UIManager:close(dialog)
                self:syncChanged()
                if on_saved then on_saved() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Under Tools: a way in, and the one choice Settings does not hold. Everything
--- else is edited in Settings.
function Nightstand:addToMainMenu(menu_items)
    menu_items.nightstand = {
        text = MENU_TEXT,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open Nightstand"),
                callback = function() self:open() end,
            },
            {
                text = _("Use Nightstand instead of the file browser"),
                help_text = _([[Shows the home screen whenever the file browser would appear: at startup and after closing a book. Close it to reach the file browser underneath.]]),
                checked_func = function() return Settings:get("replace_file_browser") end,
                callback = function() Settings:toggle("replace_file_browser") end,
            },
            {
                text = _("Settings…"),
                callback = function() self:openSettings() end,
            },
        },
    }
end

return Nightstand
