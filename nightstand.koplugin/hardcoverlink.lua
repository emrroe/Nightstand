--[[--
The "Connect Hardcover" screen: a QR code that opens the approval page with
the code filled in, and the URL and code spelled out for anyone who can't scan
it. Polls in the background until the user approves, denies, or it expires.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local QRWidget = require("ui/widget/qrwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Dialogs = require("dialogs")
local Hardcover = require("hardcover")
local NightstandScreen = require("screen")
local Dim = require("dim")
local _ = require("gettext")
local T = require("ffi/util").template

local W = require("widgets")
local BLACK, MUTED = W.BLACK, W.MUTED

local HardcoverLink = NightstandScreen:extend{
    name = "nightstand_hardcover_link",
    on_linked = nil,
}

function HardcoverLink:load()
    self.state = self.state or "starting"
    -- let the screen paint before the first network round trip
    if self.state == "starting" then UIManager:nextTick(function() self:start() end) end
end

function HardcoverLink:start()
    local device, err = Hardcover:startLink()
    if not device then
        self.state = "error"
        self.message = T(_("Could not start sign-in: %1"), err)
        return self:rebuild()
    end
    self.device = device
    self.interval = tonumber(device.interval) or 5
    self.deadline = os.time() + (tonumber(device.expires_in) or 900)
    self.state = "waiting"
    self:rebuild()
    self:schedulePoll()
end

function HardcoverLink:schedulePoll()
    self.poll_fn = function() self:pollOnce() end
    UIManager:scheduleIn(self.interval, self.poll_fn)
end

function HardcoverLink:pollOnce()
    self.poll_fn = nil
    if self.closed then return end
    if os.time() > self.deadline then
        self.state = "expired"
        return self:rebuild()
    end

    local result, err = Hardcover:poll(self.device.device_code)
    if result == "linked" then
        local username = Hardcover:fetchMe()
        self.state = "linked"
        self.message = username and T(_("Connected as @%1"), username) or _("Connected")
        self:rebuild()
        UIManager:scheduleIn(2, function()
            if not self.closed then UIManager:close(self) end
            if self.on_linked then self.on_linked() end
        end)
        return
    elseif result == "failed" then
        self.state = "error"
        self.message = err == "access_denied" and _("Sign-in was declined.")
            or T(_("Sign-in failed: %1"), err)
        return self:rebuild()
    elseif result == "slow_down" then
        self.interval = self.interval + 5
    end
    self:schedulePoll()
end

function HardcoverLink:status()
    if self.state == "starting" then return _("Contacting Hardcover…") end
    if self.state == "waiting" then return _("Waiting for you to approve…") end
    if self.state == "expired" then return _("The code has expired.") end
    return self.message or ""
end

local function line(str, face, size, colour, width)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = Dim.face(face, size).size * 1.6 },
        W.text(str, face, size, colour),
    }
end

function HardcoverLink:build()
    local w, h = self.screen_w, self.screen_h
    local inner = math.floor(w * 0.84)
    local qr_size = math.floor(math.min(w, h) * 0.42)
    local group = VerticalGroup:new{ align = "center" }
    local group_h = 0
    local function put(widget)
        table.insert(group, widget)
        group_h = group_h + widget:getSize().h
    end
    -- buttons are placed once the column is centred, so their zones are known
    local buttons = {}
    local function button(text, filled, on_tap)
        local widget = Dialogs.button(text, filled, math.floor(w * 0.5))
        table.insert(buttons, { y = group_h, widget = widget, on_tap = on_tap })
        put(widget)
        put(VerticalSpan:new{ width = Dim.px(10) })
    end

    put(line(_("Connect Hardcover"), W.BOLD, 22, BLACK, w))
    put(VerticalSpan:new{ width = Dim.px(12) })

    local device = self.device
    if device and self.state == "waiting" then
        put(TextBoxWidget:new{
            text = _("Scan the code with your phone, or go to the address below and enter the code."),
            face = Dim.face(W.REGULAR, 13),
            width = inner,
            alignment = "center",
        })
        put(VerticalSpan:new{ width = Dim.px(16) })
        -- QR needs a white quiet zone around it to scan reliably
        put(FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding = Dim.px(10),
            QRWidget:new{
                text = device.verification_uri_complete or device.verification_uri,
                width = qr_size,
                height = qr_size,
            },
        })
        put(VerticalSpan:new{ width = Dim.px(16) })
        put(line(device.verification_uri, W.REGULAR, 14, MUTED, w))
        put(line(device.user_code, "infont", 30, BLACK, w))
        put(VerticalSpan:new{ width = Dim.px(16) })
    else
        put(VerticalSpan:new{ width = qr_size * 0.5 })
    end

    put(line(self:status(), W.REGULAR, 13, MUTED, w))
    put(VerticalSpan:new{ width = Dim.px(20) })

    -- on a phone the QR code is on the very screen that would scan it
    if device and self.state == "waiting" and Device:canOpenLink() then
        button(_("Open in browser"), true, function()
            Device:openLink(device.verification_uri_complete or device.verification_uri)
        end)
    end
    if self.state == "expired" or self.state == "error" then
        button(_("Get a new code"), true, function() self:restart() end)
    end
    if self.state ~= "linked" then
        button(_("Cancel"), false, function() UIManager:close(self) end)
    end

    local top = math.floor((h - group_h) / 2)
    for _index, b in ipairs(buttons) do
        local size = b.widget:getSize()
        self:zone(math.floor((w - size.w) / 2), top + b.y, size.w, size.h, b.on_tap)
    end
    self:setContent(CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, group })
end

function HardcoverLink:restart()
    self:cancelPoll()
    self.device = nil
    self.message = nil
    self.state = "starting"
    self:reload()
end

function HardcoverLink:rebuild()
    if not self.closed then self:refresh() end
end

function HardcoverLink:cancelPoll()
    if self.poll_fn then
        UIManager:unschedule(self.poll_fn)
        self.poll_fn = nil
    end
end

function HardcoverLink:onCloseWidget()
    self.closed = true
    self:cancelPoll()
    NightstandScreen.onCloseWidget(self)
end

return HardcoverLink
