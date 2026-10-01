--[[--
Nightstand: a home screen backed by a Calibre-Web-Automated library.

The server holds the shelf, the device holds a cache of it. Books that are
not on this device are marked; everything else is a normal KOReader file.

@module koplugin.Nightstand
--]]--

local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Availability = require("availability")
local Books = require("books")
local Catalog = require("catalog")
local CoverCache = require("covercache")
local Progress = require("progress")
local Settings = require("settings")
local _ = require("gettext")
local T = require("ffi/util").template

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

function Nightstand:openAsHome()
    if not Settings:get("replace_file_browser") then return end
    if Settings:booksDir() == "" then return end
    UIManager:nextTick(function() self:open() end)
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
        on_closed = function() shown_home = nil end,
    }
    UIManager:show(shown_home)
end

--- Pull the CWA catalogue, then fetch a cover for every book that is not
--- already on the device. Deliberately synchronous: it only runs when asked.
function Nightstand:refreshCatalogue(touchmenu_instance)
    local working = InfoMessage:new{ text = _("Refreshing catalogue…") }
    UIManager:show(working)
    UIManager:forceRePaint()

    local entries, err = Catalog:refresh()
    if not entries then
        UIManager:close(working)
        UIManager:show(InfoMessage:new{
            text = T(_("Could not reach the server.\n%1"), tostring(err)),
        })
        return
    end

    Availability:invalidate()
    local shelf = Books:list(Settings:booksDir())
    local fetched = 0
    for _, entry in ipairs(shelf) do
        if not entry.on_device and not CoverCache:hasRemote(entry.book_id) then
            if CoverCache:fetchRemote(entry.book_id, entry.cover_url) then
                fetched = fetched + 1
            end
        end
    end
    local positions = Progress:refreshAll(shelf)

    UIManager:close(working)
    UIManager:show(InfoMessage:new{
        text = T(_("%1 books in the catalogue.\n%2 covers fetched.\n%3 reading positions."),
                 #entries, fetched, positions),
    })
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

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

function Nightstand:layoutMenu()
    local items = {}
    for _index, layout in ipairs(Settings.LAYOUTS) do
        table.insert(items, {
            text = layout.name,
            radio = true,
            checked_func = function() return Settings:get("layout") == layout.id end,
            callback = function() Settings:set("layout", layout.id) end,
        })
    end
    return items
end

function Nightstand:addToMainMenu(menu_items)
    menu_items.nightstand = {
        text = _("Nightstand"),
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
                text = _("Refresh catalogue when the device wakes"),
                checked_func = function() return Settings:get("refresh_on_wake") end,
                callback = function() Settings:toggle("refresh_on_wake") end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Home layout: %1"), Settings:layoutName())
                end,
                sub_item_table_func = function() return self:layoutMenu() end,
            },
            {
                text = _("Show time remaining"),
                checked_func = function() return Settings:get("time_remaining") end,
                callback = function() Settings:toggle("time_remaining") end,
                separator = true,
            },
            {
                text = _("Download over Wi-Fi only"),
                checked_func = function() return Settings:get("wifi_only") end,
                callback = function() Settings:toggle("wifi_only") end,
            },
            {
                text = _("Delete the file when a book is finished"),
                help_text = _([[Removes the downloaded file but keeps the reading position, so the book still reads as finished and can be fetched again.]]),
                checked_func = function() return Settings:get("delete_when_finished") end,
                callback = function() Settings:toggle("delete_when_finished") end,
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
