--[[--
Nightstand: a home screen backed by a Calibre-Web-Automated library.

The server holds the shelf, the device holds a cache of it. Books that are
not on this device are marked; everything else is a normal KOReader file.

@module koplugin.Nightstand
--]]--

local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Availability = require("availability")
local Books = require("books")
local Catalog = require("catalog")
local CoverCache = require("covercache")
local Progress = require("progress")
local Background = require("background")
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

function Nightstand:init()
    self.ui.menu:registerToMainMenu(self)
    -- `name = "filemanager"` lives on the FileChooser, not on FileManager, so
    -- the absence of a document is what distinguishes the two hosts.
    if not self.ui.document and self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function() self:openAsHome() end)
    end
end

--- Nightstand's own settings screen.
function Nightstand:openSettings()
    UIManager:show(require("settingsscreen"):new{ plugin = self }, "ui")
end

function Nightstand:openLibrary()
    UIManager:show(require("libraryscreen"):new{ plugin = self }, "ui")
end

--- Discover fetches from Hardcover when it has nothing, or nothing recent,
--- and the device is online; otherwise it shows what it has.
function Nightstand:openDiscover(force)
    local Discover = require("discover")
    local data = Discover:load()
    local stale = not data or os.time() - (data.fetched_at or 0) > 6 * 3600
    if (stale or force) and NetworkMgr:isOnline() then
        local working = InfoMessage:new{ text = _("Fetching recommendations from Hardcover…") }
        UIManager:show(working)
        UIManager:forceRePaint()
        local current = Books:current(Books:list(Settings:booksDir()))
        local ok, err = Discover:refresh(current and current.title)
        if ok then Discover:fetchCovers(12) end
        UIManager:close(working)
        if not ok and not data then
            UIManager:show(InfoMessage:new{ text = T(_("Could not reach Hardcover.\n%1"), tostring(err)) })
            return
        end
    end
    local DiscoverScreen = require("discoverscreen")
    if not Discover:load() then
        UIManager:show(InfoMessage:new{ text = DiscoverScreen.emptyMessage() })
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
    if not Settings:get("replace_file_browser") then return end
    if Settings:booksDir() == "" then return end
    UIManager:nextTick(function()
        self:open()
        -- first run: fetch the library rather than greet the user with nothing
        if Catalog:count() == 0 and Settings:get("server") ~= ""
           and NetworkMgr:isOnline() then
            self:refreshCatalogue()
            if shown_home then shown_home:reload() end
        end
    end)
end

function Nightstand:open()
    if Settings:booksDir() == "" then
        UIManager:show(InfoMessage:new{
            text = _("Set a books folder first, under Tools > Nightstand."),
        })
        return
    end
    if shown_home and UIManager:isWidgetShown(shown_home) then return end
    shown_home = require("homescreen"):new{
        plugin = self,
        on_closed = function() shown_home = nil end,
    }
    UIManager:show(shown_home)
end

--- Coming back from sleep: positions may have moved on another device.
--- Quietly skipped when offline; the next wake or refresh catches up.
function Nightstand:onResume()
    if not Settings:get("refresh_on_wake") then return end
    UIManager:scheduleIn(3, function()
        local home = shown_home
        if not (home and UIManager:isWidgetShown(home) and Net.isOnline()) then return end
        local moving = {}
        for _, entry in ipairs(home.entries) do
            if entry.on_device or entry.status == "reading" then table.insert(moving, entry) end
        end
        self:refreshInBackground(moving, true)
    end)
end

--- Pull the CWA catalogue (quick, shown as busy), then fetch covers and
--- reading positions in the background while the screens stay usable.
function Nightstand:refreshCatalogue(touchmenu_instance)
    local working = InfoMessage:new{ text = _("Refreshing catalogue…") }
    UIManager:show(working)
    UIManager:forceRePaint()
    local entries, err = Catalog:refresh()
    UIManager:close(working)
    if not entries then
        UIManager:show(InfoMessage:new{ text = T(_("Could not reach the server.\n%1"), tostring(err)) })
        return
    end
    Availability:invalidate()
    if touchmenu_instance then touchmenu_instance:updateItems() end
    self:refreshInBackground(Books:list(Settings:booksDir()))
end

function Nightstand:refreshInBackground(shelf, positions_only)
    if not positions_only and Net.mayDownload() then
        local missing = {}
        for _, entry in ipairs(shelf) do
            if not entry.on_device and entry.book_id and not CoverCache:hasRemote(entry.book_id) then
                table.insert(missing, entry)
            end
        end
        Background.run(missing, function(entry) CoverCache:fetchRemote(entry.book_id, entry.cover_url) end,
                       { label = _("Covers"), redraw_every = 4 })
    end
    Background.run(shelf, function(entry) Progress:refreshEntry(entry) end, {
        label = _("Positions"),
        redraw_every = 6,
        on_done = function() Progress:save() end,
    })
end

--- While background work runs, the visible screen redraws as results arrive.
local function redrawWhileLoading(final)
    for _, screen in ipairs({ shown_home }) do
        if screen and UIManager:isWidgetShown(screen) then
            if final then screen:reload() else screen:refresh() end
        end
    end
end
Background.on_progress = redrawWhileLoading

function Nightstand:editServer()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Calibre-Web-Automated server"),
        fields = {
            {
                description = _("Server address"),
                text = Settings:get("server"),
                hint = "https://books.example.org",
            },
            {
                description = _("Books folder on this device"),
                text = Settings:get("books_dir"),
                hint = "/mnt/onboard/Books",
            },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                callback = function()
                    local fields = dialog:getFields()
                    -- The CWA sync plugin appends its own path segment, so
                    -- store the bare root and never a trailing slash.
                    Settings:set("server", (fields[1] or ""):gsub("/+$", ""))
                    Settings:set("books_dir", (fields[2] or ""):gsub("/+$", ""))
                    Availability:invalidate()
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Nightstand:addToMainMenu(menu_items)
    menu_items.nightstand = {
        text = MENU_TEXT,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open Nightstand"),
                keep_menu_open = false,
                callback = function() self:open() end,
            },
            {
                text = _("Use Nightstand instead of the file browser"),
                help_text = _([[Shows the home screen whenever the file browser would appear: at startup and after closing a book. Close it to reach the file browser underneath.]]),
                checked_func = function() return Settings:get("replace_file_browser") end,
                callback = function() Settings:toggle("replace_file_browser") end,
                separator = true,
            },
            {
                text_func = function()
                    local server = Settings:get("server")
                    return T(_("Server: %1"),
                             server ~= "" and server or _("not set"))
                end,
                keep_menu_open = true,
                callback = function() self:editServer() end,
            },
            {
                text_func = function()
                    local dir = Settings:booksDir()
                    return T(_("Books folder: %1"), dir ~= "" and dir or _("not set"))
                end,
                keep_menu_open = true,
                callback = function() self:editServer() end,
            },
            {
                text_func = function()
                    local n = Catalog:count()
                    return n > 0 and T(_("Refresh catalogue (%1 books)"), n)
                                  or _("Refresh catalogue")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:refreshCatalogue(touchmenu_instance)
                end,
            },
            {
                text = _("Update reading positions when the device wakes"),
                checked_func = function() return Settings:get("refresh_on_wake") end,
                callback = function() Settings:toggle("refresh_on_wake") end,
                separator = true,
            },
            {
                text = _("Download over Wi-Fi only"),
                help_text = _("On a phone, books and covers are not downloaded over mobile data."),
                checked_func = function() return Settings:get("wifi_only") end,
                callback = function() Settings:toggle("wifi_only") end,
                separator = true,
            },
            {
                text_func = function()
                    Availability:ensure(Settings:booksDir())
                    return T(_("Books on this device: %1"), Availability:count())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    Availability:invalidate()
                    Availability:ensure(Settings:booksDir())
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                help_text = _("Tap to rebuild the index."),
            },
        },
    }
end

return Nightstand
