--[[--
KOReader's plugins, each with a switch -- the same list as KOReader's own
plugin manager, in Nightstand's look. Switching takes effect after a
restart, which is offered on leaving when anything changed.
--]]--

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local NightstandScreen = require("screen")
local TabBar = require("tabbar")
local Dim = require("dim")
local W = require("widgets")
local _ = require("gettext")

local text, hspan, rule = W.text, W.hspan, W.rule
local BLACK, MUTED, BOLD, REGULAR = W.BLACK, W.MUTED, W.BOLD, W.REGULAR

local PluginsScreen = NightstandScreen:extend{
    name = "nightstand_plugins",
    tab_id = "settings",
    pageable = true,
}

--- Every plugin KOReader found, enabled or not, by name; Nightstand itself
--- is left out so it cannot be switched off from inside itself.
function PluginsScreen.list()
    local PluginLoader = require("pluginloader")
    local enabled, disabled = PluginLoader:loadPlugins()
    local out = {}
    for _index, group in ipairs({ enabled or {}, disabled or {} }) do
        for _index2, plugin in ipairs(group) do
            if plugin.name ~= "nightstand" then
                table.insert(out, {
                    name = plugin.name,
                    label = plugin.fullname or plugin.name,
                    description = plugin.description,
                })
            end
        end
    end
    table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
    return out
end

function PluginsScreen.isOn(name)
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    return not disabled[name]
end

function PluginsScreen.set(name, on)
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    disabled[name] = not on or nil
    G_reader_settings:saveSetting("plugins_disabled", disabled)
end

function PluginsScreen:load()
    self.page = self.page or 1
    self.plugins = PluginsScreen.list()
end

function PluginsScreen:build()
    local title_h, note_h, pager_h = Dim.px(42), Dim.px(26), Dim.px(30)
    local row_h = Dim.px(52)
    local list_h = self.screen_h - title_h - note_h - pager_h - TabBar.height() - TabBar.margin()
    self.per_page = math.max(1, math.floor(list_h / row_h))
    self.pages = math.max(1, math.ceil(#self.plugins / self.per_page))
    if self.page > self.pages then self.page = self.pages end

    local stack = W.stack()
    stack:add(self:titleBand(title_h, stack.y), title_h)
    stack:add(LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = note_h },
        HorizontalGroup:new{ hspan(self.gutter),
            text(_("Changes take effect after KOReader restarts."), REGULAR, 11, MUTED,
                 self.screen_w - 2 * self.gutter) },
    }, note_h)
    local list = VerticalGroup:new{ align = "left", rule(self.screen_w) }
    local y = stack.y + Size.line.thin
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.plugins, first + self.per_page - 1) do
        list[#list + 1] = self:row(self.plugins[i], row_h - Size.line.thin, y)
        list[#list + 1] = rule(self.screen_w)
        y = y + row_h
    end
    stack:add(LeftContainer:new{ dimen = Geom:new{ w = self.screen_w, h = list_h }, list }, list_h)
    stack:add(self:pagerBand(pager_h, stack.y), pager_h)
    stack:space(TabBar.margin())
    stack:add(self:tabsBand(TabBar.height(), stack.y), TabBar.height())
    self:setContent(stack.group)
end

function PluginsScreen:titleBand(h, band_y)
    self:zone(0, band_y, self.screen_w, h, function() self:onClose() end)
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{
            align = "center",
            hspan(self.gutter),
            W.icon("chevron-left", 20),
            hspan(Dim.pad.small),
            text(_("Plugins"), BOLD, 21, BLACK),
        },
    }
end

function PluginsScreen:row(plugin, h, band_y)
    local switch = W.toggle(PluginsScreen.isOn(plugin.name))
    local text_w = self.screen_w - 2 * self.gutter - switch:getSize().w - Dim.pad.large
    local words = VerticalGroup:new{ align = "left", text(plugin.label, REGULAR, 13, BLACK, text_w) }
    if plugin.description and plugin.description ~= "" then
        words[2] = text(plugin.description:gsub("%s+", " "), REGULAR, 10.5, MUTED, text_w)
    end
    local name = plugin.name
    self:zone(0, band_y, self.screen_w, h, function()
        PluginsScreen.set(name, not PluginsScreen.isOn(name))
        self.changed = true
        self:refresh()
    end)
    return LeftContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = h },
        HorizontalGroup:new{
            align = "center",
            hspan(self.gutter),
            LeftContainer:new{ dimen = Geom:new{ w = text_w, h = h }, words },
            RightContainer:new{ dimen = Geom:new{ w = switch:getSize().w + Dim.pad.large, h = h }, switch },
        },
    }
end

function PluginsScreen:onClose()
    UIManager:close(self)
    if self.changed then UIManager:askForRestart() end
    return true
end

return PluginsScreen
