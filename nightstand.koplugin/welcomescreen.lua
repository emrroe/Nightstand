--[[--
The first thing a new reader sees: where the books live -- a
Calibre-Web-Automated server, or a folder on this device -- and then,
optionally, a Hardcover account for recommendations. Shown once, and only
when neither a server nor a books folder is set.
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local NightstandScreen = require("screen")
local Settings = require("settings")
local Dim = require("dim")
local W = require("widgets")
local _ = require("gettext")

local WelcomeScreen = NightstandScreen:extend{
    name = "nightstand_welcome",
    step = "source",   -- then "hardcover"
}

--- Whether this reader still has to choose where the books live.
function WelcomeScreen.needed()
    return not Settings:get("welcomed") and Settings:get("server") == "" and Settings:get("books_dir") == ""
end

function WelcomeScreen:build()
    local w, h = self.screen_w, self.screen_h
    local text_w = math.min(w - 4 * self.gutter, Dim.px(420))
    local column = VerticalGroup:new{ align = "left" }
    local column_h = 0
    local function put(widget)
        table.insert(column, widget)
        column_h = column_h + widget:getSize().h
    end
    local function para(text, face, size, colour)
        put(TextBoxWidget:new{ text = text, face = Dim.face(face, size), fgcolor = colour, width = text_w })
    end

    -- the choices, each a card: icon, title, a sentence; placed once the
    -- column is centred, so their tap zones are known
    local choices = {}
    local function choice(icon, title, text, on_tap, filled)
        local inner = text_w - 2 * Dim.pad.large
        local words = VerticalGroup:new{ align = "left",
            TextBoxWidget:new{ text = title, face = Dim.face(W.BOLD, 14), width = inner - Dim.px(40),
                               fgcolor = filled and W.WHITE or W.BLACK, bgcolor = filled and W.BLACK or nil },
            VerticalSpan:new{ width = Dim.pad.small },
            TextBoxWidget:new{ text = text, face = Dim.face(W.REGULAR, 11.5), width = inner - Dim.px(40),
                               fgcolor = filled and W.WHITE or W.MUTED, bgcolor = filled and W.BLACK or nil },
        }
        local card = FrameContainer:new{
            background = filled and W.BLACK or W.WHITE, color = W.BLACK, bordersize = Size.border.thin,
            radius = Dim.px(10), padding = Dim.pad.large, margin = 0,
            HorizontalGroup:new{ align = "top", W.icon(icon, 24), W.hspan(Dim.px(16)), words },
        }
        table.insert(choices, { y = column_h, widget = card, on_tap = on_tap })
        put(card)
        put(VerticalSpan:new{ width = Dim.pad.large })
    end

    if self.step == "source" then
        para(_("Welcome to Nightstand"), W.BOLD, 24, W.BLACK)
        put(VerticalSpan:new{ width = Dim.pad.default })
        para(_("A home screen for your books. Where do they live?"), W.REGULAR, 13.5, W.MUTED)
        put(VerticalSpan:new{ width = Dim.px(28) })
        choice("server", _("On a Calibre-Web-Automated server"),
               _("Your whole library to browse and download, with reading positions kept in sync across your devices."),
               function() self:chooseServer() end)
        choice("folder", _("In a folder on this device"),
               _("The EPUB files you copy to this device. No server needed."),
               function() self:chooseFolder() end)
    else
        para(_("Recommendations"), W.BOLD, 24, W.BLACK)
        put(VerticalSpan:new{ width = Dim.pad.default })
        para(_("Connect a free Hardcover account to get suggestions for what to read next and keep a Want to read list. You can also do this later in Settings."),
             W.REGULAR, 13.5, W.MUTED)
        put(VerticalSpan:new{ width = Dim.px(28) })
        choice("tab-discover-on", _("Connect Hardcover"),
               _("Sign in by scanning a code with your phone."), function() self:connectHardcover() end)
        choice("chevron-right", _("Not now"), _("Go to your books."), function() self:finish() end)
    end

    local top = math.floor((h - column_h) / 2)
    local x = math.floor((w - text_w) / 2)
    for _index, c in ipairs(choices) do
        local size = c.widget:getSize()
        self:zone(x, top + c.y, size.w, size.h, c.on_tap)
    end
    self:setContent(W.fullscreen(w, h, CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, column }))
end

-- Nothing to return to from here, so Back stays on this screen.
function WelcomeScreen:onClose()
    return true
end

function WelcomeScreen:chooseServer()
    self.plugin:editServer(function()
        if Settings:get("server") == "" then return end
        if Settings:get("sync_service") == nil then Settings:set("sync_service", "cwa") end
        self:next()
    end)
end

function WelcomeScreen:chooseFolder()
    local Device = require("device")
    local start = G_reader_settings:readSetting("home_dir") or Device.home_dir or "/"
    UIManager:show(require("ui/widget/pathchooser"):new{
        select_directory = true, select_file = false, path = start,
        onConfirm = function(path)
            Settings:set("books_dir", (path:gsub("/+$", "")))
            if Settings:get("sync_service") == nil then Settings:set("sync_service", "off") end
            self:next()
        end,
    })
end

function WelcomeScreen:next()
    self.step = "hardcover"
    self:refresh()
end

function WelcomeScreen:connectHardcover()
    require("ui/network/manager"):runWhenOnline(function()
        UIManager:show(require("hardcoverlink"):new{ on_linked = function() self:finish() end })
    end)
end

--- Done: remember it, and open Home (fetching the library from a server).
function WelcomeScreen:finish()
    Settings:set("welcomed", true)
    require("availability"):invalidate()
    UIManager:close(self)
    if self.plugin then self.plugin:openAsHome() end
end

return WelcomeScreen
