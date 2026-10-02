--[[--
The "Connect Hardcover" screen: a QR code that opens the approval page with
the code filled in, and the URL and code spelled out for anyone who can't scan
it. Polls in the background until the user approves, denies, or it expires.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Hardcover = require("hardcover")
local Dim = require("dim")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template

local W = require("widgets")
local BLACK, GREY = W.BLACK, W.GREY

local HardcoverLink = InputContainer:extend{
    name = "nightstand_hardcover_link",
    covers_fullscreen = true,
    on_linked = nil,
}

function HardcoverLink:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.state = "starting"
    self:build()
    -- let the screen paint before the first network round trip
    UIManager:nextTick(function() self:start() end)
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

    table.insert(group, line(_("Connect Hardcover"), W.SERIF, 22, BLACK, w))
    table.insert(group, VerticalSpan:new{ width = Dim.px(12) })

    local device = self.device
    if device and self.state == "waiting" then
        table.insert(group, TextBoxWidget:new{
            text = _("Scan the code with your phone, or go to the address below and enter the code."),
            face = Dim.face("cfont", 13),
            width = inner,
            alignment = "center",
        })
        table.insert(group, VerticalSpan:new{ width = Dim.px(16) })
        -- QR needs a white quiet zone around it to scan reliably
        table.insert(group, FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding = Dim.px(10),
            QRWidget:new{
                text = device.verification_uri_complete or device.verification_uri,
                width = qr_size,
                height = qr_size,
            },
        })
        table.insert(group, VerticalSpan:new{ width = Dim.px(16) })
        table.insert(group, line(device.verification_uri, "infont", 14, GREY, w))
        table.insert(group, line(device.user_code, "infont", 30, BLACK, w))
        table.insert(group, VerticalSpan:new{ width = Dim.px(16) })
    else
        table.insert(group, VerticalSpan:new{ width = qr_size * 0.5 })
    end

    table.insert(group, line(self:status(), "cfont", 13, GREY, w))
    table.insert(group, VerticalSpan:new{ width = Dim.px(20) })

    local buttons = VerticalGroup:new{ align = "center" }
    -- on a phone the QR code is on the very screen that would scan it
    if device and self.state == "waiting" and Device:canOpenLink() then
        table.insert(buttons, Button:new{
            text = _("Open in browser"),
            width = math.floor(w * 0.5),
            callback = function()
                Device:openLink(device.verification_uri_complete or device.verification_uri)
            end,
        })
        table.insert(buttons, VerticalSpan:new{ width = Dim.px(10) })
    end
    if self.state == "expired" or self.state == "error" then
        table.insert(buttons, Button:new{
            text = _("Get a new code"),
            width = math.floor(w * 0.5),
            callback = function() self:restart() end,
        })
        table.insert(buttons, VerticalSpan:new{ width = Dim.px(10) })
    end
    if self.state ~= "linked" then
        table.insert(buttons, Button:new{
            text = _("Cancel"),
            width = math.floor(w * 0.5),
            callback = function() UIManager:close(self) end,
        })
    end
    table.insert(group, buttons)

    self[1] = FrameContainer:new{
        width = w, height = h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, group },
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

function HardcoverLink:restart()
    self:cancelPoll()
    self.device = nil
    self.message = nil
    self.state = "starting"
    self:rebuild()
    UIManager:nextTick(function() self:start() end)
end

function HardcoverLink:rebuild()
    if self.closed then return end
    self:build()
    UIManager:setDirty(self, "ui")
end

function HardcoverLink:cancelPoll()
    if self.poll_fn then
        UIManager:unschedule(self.poll_fn)
        self.poll_fn = nil
    end
end

function HardcoverLink:onClose()
    UIManager:close(self)
    return true
end

function HardcoverLink:onCloseWidget()
    self.closed = true
    self:cancelPoll()
    UIManager:setDirty(nil, "full")
end

return HardcoverLink
