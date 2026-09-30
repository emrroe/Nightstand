--[[--
Nightstand: a home screen backed by a Calibre-Web-Automated library.

The server holds the shelf, the device holds a cache of it. Books that are
not on this device are marked; everything else is a normal KOReader file.

@module koplugin.Nightstand
--]]--

local DoubleSpinWidget = require("ui/widget/doublespinwidget")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Availability = require("availability")
local Settings = require("settings")
local _ = require("gettext")
local T = require("ffi/util").template

local Nightstand = WidgetContainer:extend{
    name = "nightstand",
    is_doc_only = false,
}

function Nightstand:init()
    self.ui.menu:registerToMainMenu(self)
end

function Nightstand:open()
    -- The layouts land next; until then, say plainly what is configured.
    UIManager:show(InfoMessage:new{
        text = T(_("Nightstand layout: %1\nBooks on this device: %2"),
                 Settings:layoutName(),
                 Availability:ensure(Settings:get("books_dir")) and Availability:count()),
    })
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

function Nightstand:editGrid(touchmenu_instance)
    UIManager:show(DoubleSpinWidget:new{
        title_text = _("Covers per page"),
        left_text = _("Columns"),
        right_text = _("Rows"),
        left_value = Settings:get("grid_cols"),
        right_value = Settings:get("grid_rows"),
        left_min = 2, left_max = 8, left_default = Settings.DEFAULTS.grid_cols,
        right_min = 1, right_max = 6, right_default = Settings.DEFAULTS.grid_rows,
        callback = function(cols, rows)
            Settings:set("grid_cols", cols)
            Settings:set("grid_rows", rows)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
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
                    return T(_("Books folder: %1"),
                             Settings:get("books_dir") ~= ""
                                 and Settings:get("books_dir") or _("not set"))
                end,
                keep_menu_open = true,
                callback = function() self:editServer() end,
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
                text_func = function()
                    return T(_("Covers per page: %1 × %2"),
                             Settings:get("grid_cols"), Settings:get("grid_rows"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editGrid(touchmenu_instance)
                end,
                enabled_func = function() return Settings:get("layout") ~= "list" end,
            },
            {
                text = _("Captions under covers"),
                checked_func = function() return Settings:get("captions") end,
                callback = function() Settings:toggle("captions") end,
                enabled_func = function() return Settings:get("layout") ~= "list" end,
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
                    Availability:ensure(Settings:get("books_dir"))
                    return T(_("Books on this device: %1"), Availability:count())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    Availability:invalidate()
                    Availability:ensure(Settings:get("books_dir"))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                help_text = _("Tap to rebuild the index."),
            },
        },
    }
end

return Nightstand
