local T = require("t")

-- `_` is gettext in every plugin file; a loop variable named `_` silently
-- shadows it, and any _("...") inside the loop then calls a number.
T.describe("lint", function()
    T.it("no loop shadows gettext's _", function()
        local dir = os.getenv("PLUGIN")
        for name in require("libs/libkoreader-lfs").dir(dir) do
            if name:match("%.lua$") then
                local n = 0
                for line in io.lines(dir .. "/" .. name) do
                    n = n + 1
                    T.ok(not line:match("for%s+_%s*,") and not line:match("local%s+_%s*,"),
                         string.format("%s:%d shadows _: %s", name, n, line))
                end
            end
        end
    end)
end)

T.finish()
