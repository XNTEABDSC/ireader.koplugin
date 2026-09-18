--[[--
Crash canary.

Some of what this plugin does (JNI calls into vendor classes, `Runtime.exec`
through the launcher, writes to sysfs) can fail in ways that kill the whole
process instead of raising a catchable Lua error.  A process that dies like that
takes KOReader with it, and there is no log to explain it.

The canary makes such a death survivable and self-diagnosing:

    canary.begin("epdc")     -- drop a marker file, then do the risky thing
    ...risky call...
    canary.finish("epdc")    -- remove the marker

If the process dies inside the risky call, the marker survives.  On the next
start `canary.poisoned("epdc")` is true, and the plugin refuses to touch that
code path again until the user explicitly re-enables it from the menu.

Markers live in KOReader's settings directory:
    <settings>/ireader_epdc.pending
    <settings>/ireader_frontlight.pending

@module ireader.canary
]]

local M = {}

local settings_dir = nil
local resolved = false
local cached_version = nil

local function get_settings_dir()
    if resolved then
        return settings_dir
    end
    resolved = true
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage then
        return nil
    end
    local ok2, dir = pcall(function() return DataStorage:getSettingsDir() end)
    if ok2 and type(dir) == "string" then
        settings_dir = dir
    end
    return settings_dir
end

function M.path(name)
    local dir = get_settings_dir()
    if not dir then
        return nil
    end
    return dir .. "/ireader_" .. name .. ".pending"
end

--- The plugin version, so a poisoning from an older build can be treated as
-- stale (the code that crashed has been replaced).
local function plugin_version()
    if cached_version ~= nil then
        return cached_version
    end
    cached_version = "unknown"
    local source = debug.getinfo(1, "S").source
    local path = source:sub(1, 1) == "@" and source:sub(2) or source
    local dir = path:match("^(.*[/\\])") or "./"
    local ok, meta = pcall(dofile, dir .. ".." .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        cached_version = tostring(meta.version)
    end
    return cached_version
end

--- Did a previous run die while this code path was armed?
-- A marker written by a *different* plugin version is considered stale: the
-- crashing code is gone, so it is fair to try once more.
function M.poisoned(name)
    local path = M.path(name)
    if not path then
        return false
    end
    local f = io.open(path, "r")
    if not f then
        return false
    end
    local content = f:read("*a") or ""
    f:close()
    local version = content:match("version=([^\r\n]+)")
    if version and version ~= plugin_version() then
        os.remove(path)
        return false
    end
    return true
end

--- Arm the canary for `name`.  Returns true if the marker was written.
function M.begin(name)
    local path = M.path(name)
    if not path then
        return false
    end
    local f = io.open(path, "w")
    if not f then
        return false
    end
    f:write("version=" .. plugin_version() .. "\n")
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    f:close()
    return true
end

--- Disarm the canary: the risky call returned, so we are still alive.
function M.finish(name)
    local path = M.path(name)
    if path then
        os.remove(path)
    end
end

--- Forget a poisoning (user pressed "re-enable").
function M.clear(name)
    M.finish(name)
end

--- Human readable state, for the diagnostic report.
function M.report()
    local lines = {}
    for _, name in ipairs({ "epdc", "frontlight" }) do
        lines[#lines + 1] = string.format("%s: %s", name,
            M.poisoned(name) and "DISABLED after a previous crash" or "ok")
    end
    lines[#lines + 1] = "settings dir: " .. tostring(get_settings_dir())
    return table.concat(lines, "\n")
end

return M
