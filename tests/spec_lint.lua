local T = require("t")

local dir = os.getenv("PLUGIN")
local function files()
    local out = {}
    for name in require("libs/libkoreader-lfs").dir(dir) do
        if name:match("%.lua$") then table.insert(out, name) end
    end
    table.sort(out)
    return out
end

-- `_` is gettext in every plugin file; a variable named `_` silently
-- shadows it, and any _("...") in its scope then calls a number.
T.describe("lint", function()
    T.it("nothing shadows gettext's _", function()
        for _index, name in ipairs(files()) do
            local n = 0
            for line in io.lines(dir .. "/" .. name) do
                n = n + 1
                T.ok(not line:match("for%s+_%s*[,%s]") and not line:match("local%s+_%s*,")
                     and not line:match("function%s*[%w_.:]*%(_%s*[,)]"),
                     string.format("%s:%d shadows _: %s", name, n, line))
            end
        end
    end)
    -- a module used without its `local X = require(...)` is a global read,
    -- nil at run time; the bytecode lists every global a file reads
    T.it("no file reads a global it never defined", function()
        local known = {}
        for name in pairs(_G) do known[name] = true end
        for _index, name in ipairs({ "G_reader_settings", "G_defaults" }) do known[name] = true end
        for _index, name in ipairs(files()) do
            local listing = io.popen("./luajit -bl '" .. dir .. "/" .. name .. "' 2>&1"):read("*a")
            T.ok(listing:match("^%-%- BYTECODE"), name .. " does not compile: " .. listing:sub(1, 200))
            for global in listing:gmatch('GGET%s+%d+%s+%d+%s+; "([^"]+)"') do
                T.ok(known[global], string.format("%s reads the undefined global %s", name, global))
            end
        end
    end)
end)

T.finish()
