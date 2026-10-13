--[[--
Nightstand's own settings, as a full screen rather than a drop-down.

KOReader's TouchMenu hides each value inside its label and only uses the top
two thirds of the screen. This shows one row per setting with its value on the
right, and keeps the footer tabs so Settings is a place rather than a popup.
The last row hands over to KOReader's own menu for everything else.
--]]--

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local NightstandScreen = require("screen")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local NetworkMgr = require("ui/network/manager")
local Availability = require("availability")
local Catalog = require("catalog")
local Hardcover = require("hardcover")
local HardcoverLink = require("hardcoverlink")
local Dialogs = require("dialogs")
local SyncServer = require("syncserver")
local Updater = require("updater")
local Vendors = require("vendors")
local Settings = require("settings")
local TabBar = require("tabbar")
local Dim = require("dim")
local _ = require("gettext")
local T = require("ffi/util").template

local W = require("widgets")
local text, toggle = W.text, W.toggle
local BLACK, MUTED, FAINT, BOLD, REGULAR = W.BLACK, W.MUTED, W.FAINT, W.BOLD, W.REGULAR

local SettingsScreen = NightstandScreen:extend{
    name = "nightstand_settings",
    tab_id = "settings",
    pageable = true,
}

function SettingsScreen:groups()
    local plugin = self.plugin
    local books_dir = Settings:booksDir()
    return {
        { _("Library"), self:libraryRows(books_dir) },
        { _("Hardcover"), self:hardcoverRows() },
        { _("Sync"), self:syncRows() },
        { _("Downloads"), {
            { label = _("Over Wi-Fi only"), key = "wifi_only" },
        }},
        { _("This device"), {
            { label = _("Books held locally"),
              value = T(_("%1 of %2"), Availability:count(), Catalog:count()),
              action = function()
                  Availability:invalidate()
                  Availability:ensure(books_dir)
                  self:refresh()
              end },
            { label = _("KOReader plugins"), chevron = true,
              action = function() UIManager:show(require("pluginsscreen"):new{ plugin = plugin }, "ui") end },
            { label = _("All KOReader settings"), chevron = true,
              action = function() plugin:openKoreaderMenu() end },
        }},
        { _("About"), {
            { label = _("Version"), value = Updater.currentVersion() },
            { label = _("Check for updates"), value = self:updateStatus(),
              action = function() self:checkForUpdates() end },
        }},
    }
end

-- sync ---------------------------------------------------------------------------

local SYNC_LABELS = {
    cwa = _("CWA server"),
    public = _("KOReader's public server"),
    custom = _("Another sync server"),
    off = _("Off"),
}

function SettingsScreen:syncRows()
    local chosen = Settings:get("sync_service") or "off"
    local current = SyncServer.current()
    local rows = {
        { label = _("Reading positions"), value = SYNC_LABELS[chosen] or chosen,
          action = function() self:chooseSync() end },
    }
    if chosen == "custom" then
        table.insert(rows, { label = _("Server address"), value = Settings:get("sync_url") or _("not set"),
                             action = function() self:syncAccount("custom") end })
    end
    if chosen == "public" or chosen == "custom" then
        table.insert(rows, { label = _("Account"),
                             value = current.kind ~= "off" and current.username or _("not signed in"),
                             action = function() self:syncAccount(chosen) end })
    elseif chosen == "cwa" and current.kind == "off" then
        table.insert(rows, { label = _("Account"), value = _("set the server first"),
                             action = function() self.plugin:editServer() end })
    end
    return rows
end

function SettingsScreen:chooseSync()
    local options = {
        { id = "cwa", label = SYNC_LABELS.cwa },
        { id = "public", label = SYNC_LABELS.public },
        { id = "custom", label = SYNC_LABELS.custom },
        { id = "off", label = _("Off: keep positions on this device") },
    }
    NightstandScreen.menu(_("Sync reading positions through"), options, Settings:get("sync_service") or "off",
        function(spec)
            Settings:set("sync_service", spec.id)
            self:refresh()
            if (spec.id == "public" or spec.id == "custom") and SyncServer.current().kind == "off" then
                self:syncAccount(spec.id)
            end
        end)
end

--- Sign in to (or create an account on) the public or another sync server.
function SettingsScreen:syncAccount(kind)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local fields = {}
    if kind == "custom" then
        table.insert(fields, { description = _("Server address"), text = Settings:get("sync_url") or "",
                               hint = "https://sync.example.com" })
    end
    table.insert(fields, { description = _("Username"), text = Settings:get("sync_username") or "" })
    table.insert(fields, { description = _("Password"), text = "", text_type = "password" })
    local dialog
    local function submit(create)
        local values = dialog:getFields()
        local url = kind == "custom" and values[1] or SyncServer.PUBLIC
        local user, password = values[#values - 1], values[#values]
        if url == "" or user == "" or password == "" then return end
        UIManager:close(dialog)
        require("net").whenOnline(function()
            local ok, result
            if create then
                ok, result = SyncServer.register(url, user, password)
            else
                ok, result = SyncServer.signIn(url, user, password)
            end
            if not ok then
                Dialogs.note(T(_("That did not work: %1"), tostring(result)))
                return
            end
            if kind == "custom" then Settings:set("sync_url", url) end
            Settings:set("sync_username", user)
            Settings:set("sync_userkey", result)
            self:refresh()
            Dialogs.note(create and _("Account created. Reading positions now sync.")
                                or _("Signed in. Reading positions now sync."))
        end)
    end
    dialog = MultiInputDialog:new{
        title = kind == "public" and _("KOReader's public sync server") or _("Sync server"),
        fields = fields,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Create account"), callback = function() submit(true) end },
            { text = _("Sign in"), is_enter_default = true, callback = function() submit(false) end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SettingsScreen:updateStatus()
    if Updater.isDevelopmentCopy() then return _("development copy") end
    local available = Settings:get("update_available")
    if available and Updater.newer(available, Updater.currentVersion()) then
        return T(_("%1 available"), available)
    end
    return ""
end

--- Look for a newer release, and offer to install it.
function SettingsScreen:checkForUpdates()
    if Updater.isDevelopmentCopy() then
        Dialogs.note(_("This copy of Nightstand runs from a development checkout. Update it with git instead."))
        return
    end
    require("net").whenOnline(function()
        local working = Dialogs.working(_("Checking for updates…"))
        local release, err = Updater.latest()
        UIManager:close(working)
        if not release then
            Dialogs.note(T(_("Could not check for updates.\n%1"), tostring(err)))
            return
        end
        local current = Updater.currentVersion()
        if not Updater.newer(release.version, current) then
            Settings:delete("update_available")
            self:refresh()
            Dialogs.note(T(_("Nightstand %1 is the latest version."), current))
            return
        end
        Settings:set("update_available", release.version)
        self:refresh()
        local notes = release.notes:gsub("\r", "")
        if #notes > 700 then notes = notes:sub(1, 700) .. "…" end
        require("dialogs").confirm{
            title = T(_("Nightstand %1 is available"), release.version),
            text = T(_("You have %1.\n\n%2\n\nInstall it now? KOReader restarts afterwards."), current, notes),
            ok_text = _("Update"),
            ok_callback = function() self:installUpdate(release) end,
        }
    end)
end

function SettingsScreen:installUpdate(release)
    local working = Dialogs.working(T(_("Installing Nightstand %1…"), release.version))
    local ok, err = Updater.install(release)
    UIManager:close(working)
    if not ok then
        Dialogs.note(T(_("The update failed; nothing was changed.\n%1"), tostring(err)))
        return
    end
    Settings:delete("update_available")
    UIManager:askForRestart(T(_("Nightstand %1 is installed. Restart KOReader to use it."), release.version))
end

--- With a CWA server: the server, its catalogue and refreshing it. Without
--- one, the books folder is the whole library.
function SettingsScreen:libraryRows(books_dir)
    local plugin = self.plugin
    local server = Settings:get("server")
    local rows = {
        { label = _("Server"), value = server ~= "" and server or _("none: books folder only"),
          action = function() plugin:editServer() end },
        { label = _("Books folder"),
          value = books_dir ~= "" and books_dir or _("not set"),
          action = function() plugin:editServer() end },
    }
    if server ~= "" then
        table.insert(rows, { label = _("Refresh catalogue"),
                             value = T(_("%1 books"), Catalog:count()),
                             action = function() plugin:refreshCatalogue() self:refresh() end })
        table.insert(rows, { label = _("Update positions when the device wakes"), key = "refresh_on_wake" })
    end
    return rows
end

function SettingsScreen:hardcoverRows()
    local rows = { self:hardcoverRow() }
    if Hardcover:isLinked() then
        table.insert(rows, { label = _("Find books on"), value = Vendors.current().name,
                             action = function() self:chooseVendor() end })
        table.insert(rows, { label = _("Mark finished books as read on Hardcover"),
                             key = "hardcover_mark_finished" })
    end
    return rows
end

function SettingsScreen:chooseVendor()
    local current = Vendors.current().id
    local items = {}
    for _index, vendor in ipairs(Vendors.all()) do
        local id = vendor.id
        table.insert(items, { text = vendor.name, checked = id == current, callback = function()
            Settings:set("vendor", id)
            self:refresh()
        end })
    end
    table.insert(items, { text = _("Add your own…"), separated = true, callback = function() self:addVendor() end })
    require("dialogs").menu{ title = _("Find books on"), items = items }
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
                self:refresh()
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
            on_linked = function() self:refresh() end,
        })
    end)
end

function SettingsScreen:confirmUnlink()
    require("dialogs").confirm{
        title = _("Disconnect Hardcover?"),
        text = T(_("The account @%1 is disconnected from this device; your recommendations here are cleared."), Hardcover:username() or "?"),
        ok_text = _("Disconnect"),
        ok_callback = function()
            -- offline, the token is only forgotten; it lapses on Hardcover's side
            if NetworkMgr:isOnline() then Hardcover:unlink() else Hardcover:forget() end
            -- someone else's recommendations must not linger after a disconnect
            require("discover"):clear()
            self:refresh()
        end,
    }
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
            text(_("Settings"), BOLD, 21),
        },
    }, title_h)
    add(LineWidget:new{ background = FAINT, dimen = Geom:new{ w = w, h = Size.line.thin } },
        Size.line.thin)

    -- One column if it fits. Otherwise a landscape screen splits the groups
    -- into two balanced columns, and a portrait one into pages: half-width
    -- columns would cut every label short.
    local groups = self:groups()
    local function groupHeight(group)
        return header_h + #group[2] * (row_h + Size.line.thin)
    end
    local total = 0
    for _index, group in ipairs(groups) do total = total + groupHeight(group) end
    local room = h - y - tabs_h - tabs_margin
    local columns = { groups }
    local pager_h = Dim.px(30)
    self.page, self.pages = self.page or 1, 1
    if total > room and w <= h then
        local pages, current, used = {}, {}, 0
        for _index, group in ipairs(groups) do
            if #current > 0 and used + groupHeight(group) > room - pager_h then
                table.insert(pages, current)
                current, used = {}, 0
            end
            table.insert(current, group)
            used = used + groupHeight(group)
        end
        table.insert(pages, current)
        self.pages = #pages
        self.page = math.min(self.page, self.pages)
        columns = { pages[self.page] }
    elseif total > room then
        local left, right, acc = {}, {}, 0
        for _index, group in ipairs(groups) do
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
                    text(group[1], BOLD, 11.5, MUTED),
                },
            }, header_h)
            for _i, item in ipairs(group[2]) do
                put(self:rowBand(item, row_h, cy, x, col_w), row_h)
                put(LineWidget:new{
                        background = FAINT,
                        dimen = Geom:new{ w = col_w, h = Size.line.thin } },
                    Size.line.thin)
            end
        end
        table.insert(row, column)
        col_h = math.max(col_h, cy - y)
    end
    add(row, col_h)

    -- push the pager and the tabs to the bottom
    local below = tabs_h + tabs_margin + (self.pages > 1 and pager_h or 0)
    local filler = h - y - below
    if filler > 0 then add(VerticalSpan:new{ width = filler }, filler) end
    if self.pages > 1 then add(self:pagerBand(pager_h, y), pager_h) end
    add(VerticalSpan:new{ width = tabs_margin }, tabs_margin)

    local tabs_y = y
    add(self:tabsBand(tabs_h, tabs_y), tabs_h)

    self:setContent(stack)
end

function SettingsScreen:turnPage(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    self:refresh()
end

function SettingsScreen:rowBand(row, h, band_y, band_x, w)
    band_x = band_x or 0
    w = w or self.screen_w
    local right
    if row.on ~= nil then
        right = toggle(row.on)
    elseif row.key ~= nil then
        right = toggle(Settings:get(row.key))
    elseif row.chevron then
        right = text("›", REGULAR, 16, MUTED)
    else
        right = text(row.value, REGULAR, 12, MUTED,
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
            self:refresh()
        end)
    end

    return LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = self.gutter },
            LeftContainer:new{
                dimen = Geom:new{ w = label_w, h = h },
                text(row.label, REGULAR, 13, BLACK, label_w),
            },
            RightContainer:new{
                dimen = Geom:new{ w = right_w + Dim.pad.large, h = h },
                right,
            },
            HorizontalSpan:new{ width = self.gutter },
        },
    }
end

return SettingsScreen
