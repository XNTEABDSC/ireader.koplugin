--[[--
Diagnostic report generation.

The iReader frontlight interface is not publicly documented, and the only
evidence available (sysfs `lm3630a_leda`/`ledb` on an iReader Ocean 5 Pro) comes
from a different model.  This module collects everything needed to identify the
interface on the actual device in one go, so the report can be shared and the
adapter can be pointed at the right node without guesswork.

Nothing here writes to the device: it is read-only probing plus a shell
`getprop`/`settings list`/`pm list` sweep.

@module ireader.diag
]]

local logger = require("logger")

local function sibling(name)
    local key = "ireader_lib_" .. name
    if package.loaded[key] == nil then
        local source = debug.getinfo(1, "S").source
        local path = source:sub(1, 1) == "@" and source:sub(2) or source
        local dir = path:match("^(.*[/\\])") or "./"
        package.loaded[key] = dofile(dir .. name .. ".lua")
    end
    return package.loaded[key]
end

local jni = sibling("jni")
local canary = sibling("canary")

local M = {}

local refs = {}

function M.setup(context)
    refs = context or {}
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

local function sh(cmd)
    -- Absolute paths: an app's PATH may be too small for the shell wrappers
    -- (this is why `settings list` came back empty).
    local out = jni.stdout("/system/bin/sh", "-c", cmd)
    if out == nil then
        out = jni.stdout("sh", "-c", cmd)
    end
    if out == nil then
        return "(failed)"
    end
    out = out:gsub("%s+$", "")
    if out == "" then
        return "(empty)"
    end
    return out
end

local function section(lines, title)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== " .. title .. " =="
end

local function kv(lines, key, value)
    lines[#lines + 1] = string.format("%-28s %s", key .. ":", tostring(value))
end

local function device_section(lines)
    section(lines, "Device")

    local Device
    pcall(function() Device = require("device") end)
    if Device then
        kv(lines, "koreader model", Device.model)
        kv(lines, "koreader firmware_rev", Device.firmware_rev)
        kv(lines, "isAndroid", tostring(Device:isAndroid()))
        kv(lines, "hasFrontlight", tostring(Device:hasFrontlight()))
        kv(lines, "hasNaturalLight", tostring(Device:hasNaturalLight()))
        kv(lines, "hasEinkScreen", tostring(Device:hasEinkScreen()))
    end

    local version = read_file("frontend/version.lua")
    if version then
        local rev = version:match('"(%d+%.%d+%.%d+)"') or version:match("(%d%d%d%d%.%d%d)")
        kv(lines, "koreader version", rev or "?")
    end

    if jni.android then
        kv(lines, "android.prop.product", jni.android.prop and jni.android.prop.product)
        kv(lines, "android.prop.name", jni.android.prop and jni.android.prop.name)
        kv(lines, "android.prop.flavor", jni.android.prop and jni.android.prop.flavor)
        kv(lines, "getPlatformName()", pcall(jni.android.getPlatformName) and select(2, pcall(jni.android.getPlatformName)) or "?")
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "props:"
    lines[#lines + 1] = sh("/system/bin/getprop | /system/bin/grep -Ei 'product|brand|model|board|platform|version|ireader|eink|display.id'")
end

local function sysfs_section(lines)
    section(lines, "sysfs light nodes")
    lines[#lines + 1] = sh("/system/bin/ls -l /sys/class/backlight /sys/class/leds 2>&1")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "node values and permissions:"
    lines[#lines + 1] = sh([[
for d in /sys/class/backlight/*/ /sys/class/leds/*/; do
  [ -e "$d/brightness" ] || continue
  echo "--- $d"
  /system/bin/ls -l "$d" 2>&1
  for f in brightness actual_brightness max_brightness bl_power color max_color; do
    [ -e "$d$f" ] && { echo -n "  $f="; /system/bin/cat "$d$f" 2>&1; }
  done
done]])
end

local function settings_section(lines)
    section(lines, "Android settings / packages / services")
    lines[#lines + 1] = "settings list system (light related):"
    lines[#lines + 1] = sh("/system/bin/settings list system | /system/bin/grep -Ei 'light|led|bright|warm|cold'")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "settings list global (light related):"
    lines[#lines + 1] = sh("/system/bin/settings list global | /system/bin/grep -Ei 'light|led|bright|warm|cold'")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "settings list secure (light related):"
    lines[#lines + 1] = sh("/system/bin/settings list secure | /system/bin/grep -Ei 'light|led|bright|warm|cold'")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "settings key counts:"
    lines[#lines + 1] = sh("for s in system global secure; do echo -n \"$s=\"; /system/bin/settings list $s | /system/bin/wc -l; done")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "packages:"
    lines[#lines + 1] = sh("/system/bin/pm list packages | /system/bin/grep -Ei 'zhangyue|ireader|eink|epd|light'")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "services:"
    lines[#lines + 1] = sh("/system/bin/dumpsys -l | /system/bin/grep -Ei 'light|eink|epd'")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "framework jars:"
    lines[#lines + 1] = sh("/system/bin/ls /system/framework | /system/bin/grep -Ei 'eink|ireader|epd'")
end

local function epdc_section(lines)
    section(lines, "EPDC")
    local epdc = refs.epdc
    if not epdc then
        lines[#lines + 1] = "(module not loaded)"
        return
    end
    kv(lines, "status", epdc.status())
    kv(lines, "vendor light method", epdc.light_method() or "(none found)")
    kv(lines, "config force mode", string.format("0x%08X (enabled: %s)",
        epdc.config.force_mode, tostring(epdc.config.use_force_mode)))
    kv(lines, "config directions fwd", table.concat(epdc.config.directions_forward, ","))
    kv(lines, "config directions bwd", table.concat(epdc.config.directions_backward, ","))
    kv(lines, "config speed flags", string.format("slow=%d standard=%d fast=%d",
        epdc.config.speed_flags.slow, epdc.config.speed_flags.standard, epdc.config.speed_flags.fast))

    lines[#lines + 1] = ""
    lines[#lines + 1] = "android.eink.EPDCDevice methods:"
    local methods, err = epdc.describe_class()
    if methods then
        for _, method in ipairs(methods) do
            lines[#lines + 1] = "  " .. method
        end
        if #methods == 0 then
            lines[#lines + 1] = "  (none reported)"
        end
    else
        lines[#lines + 1] = "  unavailable: " .. tostring(err)
    end
end

local function hook_section(lines)
    section(lines, "Hooks")
    if refs.frontlight then
        for line in (refs.frontlight.report() .. "\n"):gmatch("(.-)\n") do
            lines[#lines + 1] = line
        end
    end
    if refs.pageanim then
        lines[#lines + 1] = refs.pageanim.status()
    end
    section(lines, "Crash canary")
    for line in (canary.report() .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    section(lines, "Breadcrumbs (last 40)")
    local trace = refs.trace
    lines[#lines + 1] = trace and trace.tail(40) or "(trace module not wired)"
    if trace and trace.path() then
        lines[#lines + 1] = "file: " .. tostring(trace.path())
    end
end

--- Build the full report.
-- @treturn string
function M.collect()
    local lines = {
        "iReader.koplugin diagnostic report",
        "generated: " .. os.date("%Y-%m-%d %H:%M:%S"),
    }
    local steps = { device_section, sysfs_section, settings_section, epdc_section, hook_section }
    for _, step in ipairs(steps) do
        local ok, err = pcall(step, lines)
        if not ok then
            lines[#lines + 1] = "section failed: " .. tostring(err)
        end
    end
    return table.concat(lines, "\n")
end

--- Write the report to the KOReader settings directory.
-- @treturn string|nil path
function M.save(text)
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then
        return nil
    end
    local path = DataStorage:getSettingsDir() .. "/ireader_probe.log"
    local f, err = io.open(path, "w")
    if not f then
        logger.warn("[iReader] cannot write report:", err)
        return nil
    end
    f:write(text)
    f:write("\n")
    f:close()
    return path
end

return M
