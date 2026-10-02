--[[--
Nightstand's own settings, as a full screen rather than a drop-down.

KOReader's TouchMenu hides each value inside its label and only uses the top
two thirds of the screen. This shows one row per setting with its value on the
right, and keeps the footer tabs so Settings is a place rather than a popup.
The last row hands over to KOReader's own menu for everything else.
--]]--

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local Availability = require("availability")
local Catalog = require("catalog")
local Hardcover = require("hardcover")
local HardcoverLink = require("hardcoverlink")
local Vendors = require("vendors")
local Settings = require("settings")
local TabBar = require("tabbar")
local Dim = require("dim")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template

local W = require("widgets")
local text, toggle = W.text, W.toggle
local BLACK, GREY = W.BLACK, W.GREY

local SettingsScreen = InputContainer:extend{
    name = "nightstand_settings",
    covers_fullscreen = true,
}

function SettingsScreen:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.gutter = W.gutter(self.screen_w)
    self.tap_zones = {}

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = full } }
    end
    self:build()
end

function SettingsScreen:zone(x, y, w, h, callback)
    table.insert(self.tap_zones, { rect = Geom:new{ x = x, y = y, w = w, h = h }, cb = callback })
end

function SettingsScreen:groups()
    local plugin = self.plugin
    local books_dir = Settings:booksDir()
    return {
        { _("Library"), {
            { label = _("Server"), value = Settings:get("server"),
              action = function() plugin:editServer() end },
            { label = _("Books folder"),
              value = books_dir ~= "" and books_dir or _("not set"),
              action = function() plugin:editServer() end },
            { label = _("Refresh catalogue"),
              value = T(_("%1 books"), Catalog:count()),
              action = function() plugin:refreshCatalogue() self:rebuild() end },
            { label = _("Update positions when the device wakes"), key = "refresh_on_wake" },
        }},
        { _("Hardcover"), self:hardcoverRows() },
        { _("Downloads"), {
            { label = _("Over Wi-Fi only"), key = "wifi_only" },
        }},
        { _("This device"), {
            { label = _("Books held locally"),
              value = T(_("%1 of %2"), Availability:count(), Catalog:count()),
              action = function()
                  Availability:invalidate()
                  Availability:ensure(books_dir)
                  self:rebuild()
              end },
            { label = _("All KOReader settings"), chevron = true,
              action = function() plugin:openKoreaderMenu() end },
        }},
    }
end

function SettingsScreen:hardcoverRows()
    local rows = { self:hardcoverRow() }
    if Hardcover:isLinked() then
        table.insert(rows, { label = _("Find books on"), value = Vendors.current().name,
                             action = function() self:chooseVendor() end })
    end
    return rows
end

function SettingsScreen:chooseVendor()
    local ButtonDialog = require("ui/widget/buttondialog")
    local current = Vendors.current().id
    local dialog
    local buttons = {}
    for _, vendor in ipairs(Vendors.all()) do
        table.insert(buttons, {{
            text = (vendor.id == current and "✓  " or "") .. vendor.name,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                Settings:set("vendor", vendor.id)
                self:rebuild()
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Add your own…"), align = "left",
        callback = function()
            UIManager:close(dialog)
            self:addVendor()
        end,
    }})
    dialog = ButtonDialog:new{ title = _("Find books on"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function SettingsScreen:addVendor()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local input
    input = MultiInputDialog:new{
        title = _("Add a shop or library"),
        fields = {
            { description = _("Name"), text = "", hint = _("My bookshop") },
            { description = _("Search address, with {query} where the words go"), text = "",
              hint = "https://example.com/search?q={query}" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
            { text = _("Add"), is_enter_default = true, callback = function()
                local fields = input:getFields()
                local ok, err = Vendors.add(fields[1], fields[2])
                if not ok then
                    UIManager:show(require("ui/widget/infomessage"):new{ text = err })
                    return
                end
                UIManager:close(input)
                self:rebuild()
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function SettingsScreen:hardcoverRow()
    if not Hardcover:isAvailable() then
        return { label = _("Account"), value = _("not available in this build") }
    end
    if Hardcover:isLinked() then
        local name = Hardcover:username()
        return { label = _("Account"), value = name and ("@" .. name) or _("connected"),
                 action = function() self:confirmUnlink() end }
    end
    return { label = _("Account"), value = _("Connect ›"),
             action = function() self:openLink() end }
end

function SettingsScreen:openLink()
    NetworkMgr:runWhenOnline(function()
        UIManager:show(HardcoverLink:new{
            on_linked = function() self:rebuild() end,
        })
    end)
end

function SettingsScreen:confirmUnlink()
    UIManager:show(ConfirmBox:new{
        text = T(_("Disconnect Hardcover account @%1 from this device?"), Hardcover:username() or "?"),
        ok_text = _("Disconnect"),
        ok_callback = function()
            -- offline, the token is only forgotten; it lapses on Hardcover's side
            if NetworkMgr:isOnline() then Hardcover:unlink() else Hardcover:forget() end
            -- someone else's recommendations must not linger after a disconnect
            require("discover"):clear()
            self:rebuild()
        end,
    })
end

function SettingsScreen:rebuild()
    self.tap_zones = {}
    self:build()
    UIManager:setDirty(self, "ui")
end

function SettingsScreen:build()
    local w, h = self.screen_w, self.screen_h
    local tabs_h = TabBar.height()
    local tabs_margin = TabBar.margin()
    local row_h = Dim.px(34)
    local header_h = Dim.px(30)

    local y = 0
    local stack = VerticalGroup:new{ align = "left" }
    local function add(widget, height)
        table.insert(stack, widget)
        y = y + height
    end

    -- title
    local title_h = Dim.px(42)
    add(LeftContainer:new{
        dimen = Geom:new{ w = w, h = title_h },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = self.gutter },
            text(_("Settings"), W.SERIF, 20),
        },
    }, title_h)
    add(LineWidget:new{ background = GREY, dimen = Geom:new{ w = w, h = Size.line.thin } },
        Size.line.thin)

    -- One column if it fits; otherwise (landscape) the groups are split
    -- into two balanced columns rather than running off the bottom.
    local groups = self:groups()
    local function groupHeight(group)
        return header_h + #group[2] * (row_h + Size.line.thin)
    end
    local total = 0
    for _, group in ipairs(groups) do total = total + groupHeight(group) end
    local room = h - y - tabs_h - tabs_margin
    local columns = { groups }
    if total > room then
        local left, right, acc = {}, {}, 0
        for _, group in ipairs(groups) do
            if acc + groupHeight(group) / 2 <= total / 2 then
                table.insert(left, group)
                acc = acc + groupHeight(group)
            else
                table.insert(right, group)
            end
        end
        columns = { left, right }
    end

    local col_w = math.floor(w / #columns)
    local row = HorizontalGroup:new{ align = "top" }
    local col_h = 0
    for index, list in ipairs(columns) do
        local x = (index - 1) * col_w
        local cy = y
        local column = VerticalGroup:new{ align = "left" }
        local function put(widget, height)
            table.insert(column, widget)
            cy = cy + height
        end
        for _index, group in ipairs(list) do
            put(LeftContainer:new{
                dimen = Geom:new{ w = col_w, h = header_h },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = self.gutter },
                    text(group[1]:upper(), "infont", 10, GREY),
                },
            }, header_h)
            for _i, item in ipairs(group[2]) do
                put(self:rowBand(item, row_h, cy, x, col_w), row_h)
                put(LineWidget:new{
                        background = GREY,
                        dimen = Geom:new{ w = col_w, h = Size.line.thin } },
                    Size.line.thin)
            end
        end
        table.insert(row, column)
        col_h = math.max(col_h, cy - y)
    end
    add(row, col_h)

    -- push the tabs to the bottom
    local filler = h - y - tabs_h - tabs_margin
    if filler > 0 then add(VerticalSpan:new{ width = filler }, filler) end
    add(VerticalSpan:new{ width = tabs_margin }, tabs_margin)

    local tabs_y = y
    add(TabBar.build(w, tabs_h, tabs_y, "settings",
                     function(...) self:zone(...) end,
                     function(id) self:onTab(id) end), tabs_h)

    self[1] = W.fullscreen(w, h, stack)
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

function SettingsScreen:rowBand(row, h, band_y, band_x, w)
    band_x = band_x or 0
    w = w or self.screen_w
    local right
    if row.key ~= nil then
        right = toggle(Settings:get(row.key))
    elseif row.chevron then
        right = text("›", "infont", 16, GREY)
    else
        right = text(row.value, "infont", 12, GREY,
                     math.floor(w * 0.45))
    end
    local right_w = right:getSize().w
    local label_w = w - 2 * self.gutter - right_w - Dim.pad.large

    local action = row.action
    if action then
        self:zone(band_x, band_y, w, h, action)
    elseif row.key then
        local key = row.key
        self:zone(band_x, band_y, w, h, function()
            Settings:toggle(key)
            self:rebuild()
        end)
    end

    return LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = self.gutter },
            LeftContainer:new{
                dimen = Geom:new{ w = label_w, h = h },
                text(row.label, "cfont", 13, BLACK, label_w),
            },
            RightContainer:new{
                dimen = Geom:new{ w = right_w + Dim.pad.large, h = h },
                right,
            },
            HorizontalSpan:new{ width = self.gutter },
        },
    }
end

function SettingsScreen:onTab(id)
    if id == "settings" then return end
    UIManager:close(self)
    if id ~= "home" then self.plugin:openTab(id) end
end

function SettingsScreen:onTap(_widget, ges)
    for _index, zone in ipairs(self.tap_zones) do
        if zone.rect:contains(ges.pos) then
            zone.cb()
            return true
        end
    end
    return true
end

function SettingsScreen:onClose()
    UIManager:close(self)
    return true
end

function SettingsScreen:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

return SettingsScreen
