--[[--
Breadcrumb log.

When something kills the process at the native level (a JNI abort, a
Runtime.exec failure inside the launcher), KOReader never gets to write
`crash.log`, so there is no traceback to look at -- which is exactly what
happens on this device.

So we keep our own tiny log with one line per milestone, opened/closed per line
so the data is on disk *before* a possible abort.  After a crash, the last line
of the file says how far the plugin got:

    <settings>/ireader_trace.log

It is written to KOReader's settings directory (the same place as reader.lua),
so it can be pulled off the device over USB or MTP.

@module ireader.trace
]]

local M = {}

local MAX_BYTES = 64 * 1024
local KEEP_LINES = 120

local settings_dir = nil
local resolved = false

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

function M.path()
    local dir = get_settings_dir()
    if not dir then
        return nil
    end
    return dir .. "/ireader_trace.log"
end

--- Append one milestone.  Never raises, never blocks for long.
function M.step(name)
    local path = M.path()
    if not path then
        return
    end
    local f = io.open(path, "a")
    if not f then
        return
    end
    f:write(os.date("%m-%d %H:%M:%S") .. "  " .. tostring(name) .. "\n")
    f:close()
end

local function read_lines(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    local lines = {}
    for line in (data or ""):gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

--- Keep the log small: called once, at plugin load.
function M.rotate()
    local path = M.path()
    if not path then
        return
    end
    local f = io.open(path, "r")
    if not f then
        return
    end
    local size = f:seek("end")
    f:close()
    if not size or size <= MAX_BYTES then
        return
    end
    local lines = read_lines(path) or {}
    local keep = {}
    for index = math.max(1, #lines - KEEP_LINES + 1), #lines do
        keep[#keep + 1] = lines[index]
    end
    local w = io.open(path, "w")
    if w then
        w:write(table.concat(keep, "\n") .. "\n")
        w:close()
    end
end

--- Last `count` lines (used by the diagnostic report).
function M.tail(count)
    local path = M.path()
    if not path then
        return "(no settings directory)"
    end
    local lines = read_lines(path)
    if not lines or #lines == 0 then
        return "(empty)"
    end
    count = count or 30
    local out = {}
    for index = math.max(1, #lines - count + 1), #lines do
        out[#out + 1] = lines[index]
    end
    return table.concat(out, "\n")
end

--- Last recorded milestone, or nil.
function M.last_step()
    local path = M.path()
    if not path then
        return nil
    end
    local lines = read_lines(path)
    if not lines or #lines == 0 then
        return nil
    end
    return lines[#lines]
end

function M.clear()
    local path = M.path()
    if path then
        os.remove(path)
    end
end

return M
