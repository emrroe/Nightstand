local T = require("t")
local DataStorage = require("datastorage")
local rapidjson = require("rapidjson")

local work = DataStorage:getDataDir() .. "/updater-test"

--- A zip holding `files` ({ path = content }), made with Python like the test EPUBs.
local function zip(name, files)
    local path = work .. "/" .. name
    local args = {}
    for entry, content in pairs(files) do
        table.insert(args, string.format("%q", entry))
        table.insert(args, string.format("%q", content))
    end
    os.execute("mkdir -p '" .. work .. "' && python3 -c 'import sys, zipfile\n"
               .. "z = zipfile.ZipFile(sys.argv[1], \"w\")\n"
               .. "a = sys.argv[2:]\n"
               .. "[z.writestr(a[i], a[i + 1]) for i in range(0, len(a), 2)]' '"
               .. path .. "' " .. table.concat(args, " "))
    local f = io.open(path, "rb")
    local data = f:read("*a")
    f:close()
    return path, data
end

local META = 'return { fullname = "Nightstand", version = "9.9.9" }'

--- A copy of the plugin outside the git checkout, as a device has it.
local function installedCopy()
    local dir = work .. "/plugins/nightstand.koplugin"
    os.execute("rm -rf '" .. work .. "/plugins' && mkdir -p '" .. work .. "/plugins' && cp -r '"
               .. os.getenv("PLUGIN") .. "' '" .. dir .. "'")
    return dofile(dir .. "/updater.lua"), dir
end

T.describe("versions", function()
    local U = require("updater")
    T.it("compare as release numbers, pre-releases below their release", function()
        T.ok(U.newer("0.1.0-alpha.2", "0.1.0-alpha.1"))
        T.ok(U.newer("0.1.0-beta.1", "0.1.0-alpha.9"))
        T.ok(U.newer("0.1.0", "0.1.0-rc.3"))
        T.ok(U.newer("0.2.0-alpha.1", "0.1.9"))
        T.ok(U.newer("v0.10.0", "0.9.0"), "numbers, not text; a leading v is fine")
        T.ok(not U.newer("0.1.0-alpha.1", "0.1.0-alpha.1"))
        T.ok(not U.newer("0.1.0-alpha.1", "0.1.0"))
    end)
    T.it("the running version comes from _meta.lua", function()
        T.ok(U.currentVersion():match("^%d+%.%d+%.%d+"))
    end)
    T.it("the git checkout is never overwritten", function()
        T.ok(U.isDevelopmentCopy())
        local ok, err = U.install({ version = "9.9.9", url = "x" })
        T.eq(ok, false)
        T.ok(err:find("development"))
    end)
end)

T.describe("finding the latest release", function()
    T.it("picks the newest release that carries the plugin, pre-releases included", function()
        local U = require("updater")
        U.fetch = function(url)
            T.ok(url:find("api.github.com/repos/emrroe/Nightstand/releases", 1, true))
            return rapidjson.encode({
                { tag_name = "v0.3.0", draft = true, body = "",
                  assets = { { name = "nightstand.koplugin.zip", browser_download_url = "https://d/draft" } } },
                { tag_name = "v0.2.0-alpha.1", body = "Newest", prerelease = true,
                  assets = { { name = "nightstand.koplugin.zip", browser_download_url = "https://d/new" } } },
                { tag_name = "v0.2.0-alpha.2", body = "", assets = {} },
                { tag_name = "v0.1.0-alpha.1", body = rapidjson.null,
                  assets = { { name = "nightstand.koplugin.zip", browser_download_url = "https://d/old" } } },
            })
        end
        local release = U.latest()
        T.eq(release.version, "0.2.0-alpha.1")
        T.eq(release.url, "https://d/new")
        T.eq(release.notes, "Newest")
    end)
    T.it("reports a network failure or an empty list", function()
        local U = require("updater")
        U.fetch = function() return nil, "timeout" end
        local release, err = U.latest()
        T.eq(release, nil)
        T.eq(err, "timeout")
        U.fetch = function() return "[]" end
        T.eq(select(2, U.latest()), "no release found")
    end)
end)

T.describe("installing", function()
    T.it("swaps in the new version and leaves nothing behind", function()
        local U, dir = installedCopy()
        T.ok(not U.isDevelopmentCopy())
        local _path, data = zip("good.zip", {
            ["nightstand.koplugin/_meta.lua"] = META,
            ["nightstand.koplugin/main.lua"] = "return {}",
            ["nightstand.koplugin/resources/icon.svg"] = "<svg/>",
        })
        U.fetch = function() return data end
        T.ok(U.install({ version = "9.9.9", url = "https://d/zip" }))
        T.eq(dofile(dir .. "/_meta.lua").version, "9.9.9")
        T.ok(io.open(dir .. "/resources/icon.svg"), "folders inside come along")
        T.eq(io.open(dir .. "/updater.lua"), nil, "files the release dropped are gone")
        T.eq(io.open(work .. "/plugins/nightstand.koplugin.old/main.lua"), nil, "no old copy left")
        T.eq(io.open(work .. "/plugins/nightstand.koplugin.new/main.lua"), nil, "no staging left")
    end)
    T.it("refuses an incomplete or foreign zip and keeps the running copy", function()
        for name, files in pairs({
            incomplete = { ["nightstand.koplugin/_meta.lua"] = META },
            foreign = { ["nightstand.koplugin/_meta.lua"] = META, ["nightstand.koplugin/main.lua"] = "",
                        ["other/evil.lua"] = "" },
            ["not a zip"] = false,
        }) do
            local U, dir = installedCopy()
            local data = files and select(2, zip(name:gsub(" ", "_") .. ".zip", files)) or "garbage"
            U.fetch = function() return data end
            local ok, err = U.install({ version = "9.9.9", url = "https://d/zip" })
            T.eq(ok, false, name)
            T.ok(err, name .. " says why")
            T.ok(dofile(dir .. "/_meta.lua").version ~= "9.9.9", name .. ": running copy untouched")
            T.ok(io.open(dir .. "/updater.lua"), name .. ": nothing removed")
        end
    end)
    T.it("a failed download changes nothing", function()
        local U, dir = installedCopy()
        U.fetch = function() return nil, "404" end
        local ok, err = U.install({ version = "9.9.9", url = "https://d/zip" })
        T.eq(ok, false)
        T.eq(err, "404")
        T.ok(io.open(dir .. "/main.lua"))
    end)
end)

T.finish()
