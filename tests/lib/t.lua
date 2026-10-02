--[[--
A small test harness for running Nightstand inside KOReader's own LuaJIT.

run.sh starts this with KOReader's directory as the working directory and a
throwaway KO_HOME, so `require` resolves exactly as it does on a device.
--]]--

require("setupkoenv")

local plugin_dir = assert(os.getenv("PLUGIN"), "PLUGIN must point at nightstand.koplugin")
local tests_dir = assert(os.getenv("TESTS"), "TESTS must point at the tests folder")
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/lib/?.lua;" .. package.path

local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
if os.getenv("TEST_DPI") then
    G_reader_settings:saveSetting("screen_dpi", tonumber(os.getenv("TEST_DPI")))
end
-- the same start-up order as reader.lua, so UI modules find a real device
require("ffi/blitbuffer"):setUseCBB(true)
local Device = require("device")
require("document/canvascontext"):init(Device)
require("ui/uimanager")

local T = { passed = 0, failed = 0, failures = {}, path = {} }

-- Every module of the plugin keeps state at module level (caches, open
-- settings files), so each test gets fresh copies and an empty profile.
T.PLUGIN_MODULES = {
    "settings", "catalog", "books", "availability", "progress", "covercache",
    "download", "library", "hardcover", "hardcoverlink", "homescreen",
    "libraryscreen", "settingsscreen", "tabbar", "main",
}

function T.settingsDir()
    return DataStorage:getSettingsDir()
end

function T.reset()
    for _, name in ipairs(T.PLUGIN_MODULES) do package.loaded[name] = nil end
    local lfs = require("libs/libkoreader-lfs")
    local dir = T.settingsDir()
    for name in lfs.dir(dir) do
        if name:match("^nightstand") then os.remove(dir .. "/" .. name) end
    end
    os.execute("rm -rf '" .. DataStorage:getDataDir() .. "/cache/nightstand'")
end

function T.describe(name, fn)
    table.insert(T.path, name)
    fn()
    table.remove(T.path)
end

function T.it(name, fn)
    local full = table.concat(T.path, " › ") .. " › " .. name
    T.reset()
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        T.passed = T.passed + 1
        if os.getenv("VERBOSE") then print("  ok   " .. full) end
    else
        T.failed = T.failed + 1
        table.insert(T.failures, { name = full, err = err })
        print("  FAIL " .. full .. "\n" .. tostring(err):gsub("\n", "\n       "))
    end
end

local function show(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for i, x in ipairs(v) do parts[i] = show(x) end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function deepEq(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function T.eq(got, want, what)
    if not deepEq(got, want) then
        error(string.format("%s\n  got:  %s\n  want: %s", what or "values differ",
                            show(got), show(want)), 2)
    end
end

function T.ok(cond, what)
    if not cond then error(what or "expected a true value", 2) end
end

function T.finish()
    print(string.format("%d passed, %d failed", T.passed, T.failed))
    os.exit(T.failed > 0 and 1 or 0)
end

--- Titles of a list of entries, for compact assertions.
function T.titles(list)
    local out = {}
    for i, e in ipairs(list) do out[i] = e.title or e.name end
    return out
end

return T
