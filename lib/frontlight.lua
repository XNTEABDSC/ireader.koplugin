--[[--
Frontlight backend for 掌阅 (iReader) e-ink devices.

Background
----------
KOReader's Android build drives the frontlight through the launcher
(`Device.hasFrontlight = android.hasLights` -> `AndroidPowerD` ->
`android.setScreenBrightness()` -> the launcher's `GenericController`), and
`GenericController` only sets the *application window's* `screenBrightness`
attribute.  On an iReader that attribute does not reach the panel's LED driver,
which is why the frontlight cannot be adjusted from KOReader at all.

iReader has no public frontlight API: the vendor class `android.eink.EPDCDevice`
only exposes the page-turn methods (see epdc.lua), and there is no vendor
service/AIDL/broadcast that is reachable.  What is known to exist on iReader
hardware is a sysfs LED node:

    /sys/class/backlight/lm3630a_leda/brightness
    /sys/class/backlight/lm3630a_ledb/brightness      (iReader Ocean 5 Pro,
                                                       launcher issue #598)

`lm3630a` is a dual-string LED driver, which is why there are two nodes: on
dual-colour panels one string is the cold light and the other the warm light
(which one is which is not documented).  Writing to *both* with the same value
is therefore a plain brightness change.

Because that evidence comes from a different iReader model (and because sysfs
may be read-only for a non-system uid), this module probes a list of candidate
backends at runtime and lets the user pick/confirm one.  Backends, in the order
they are tried:

  1. sysfs backlight nodes (known iReader/other vendor names first, then a scan
     of /sys/class/backlight and /sys/class/leds), with an optional `su` fallback
  2. the Android framework brightness setting, `Settings.System.SCREEN_BRIGHTNESS`
     (readable without any permission; writable only with WRITE_SETTINGS)
  3. a vendor Settings key, if the user points us at one
  4. the app window brightness (always available, but only dims the window)

Everything is expressed on KOReader's 0..100 frontlight scale.

@module ireader.frontlight
]]

local ffi = require("ffi")
local logger = require("logger")

-- Shared singletons (see epdc.lua for the rationale).
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
local trace = sibling("trace")
-- Used by the experimental "EPDC light command" backend below.
local epdc = sibling("epdc")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then
    lfs = nil
end

local M = {}

local DEFAULT_LEVEL = 50

local state = {
    drivers = nil,
    active_resolved = false,
    active_driver = nil,
    first_write_done = false,
    level = nil,
    root_checked = false,
    root_available = false,
    installed = false,
    Device = nil,
    powerd = nil,
    saved = nil,
    notes = {},
}

-- ---------------------------------------------------------------------------
-- small filesystem helpers (the app runs as a normal Android uid, so all of
-- this can fail with EACCES/EROFS -- every call reports success/failure)
-- ---------------------------------------------------------------------------

local function read_int(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local line = f:read("*l")
    f:close()
    if not line then
        return nil
    end
    local value = tonumber(line:match("^%s*(-?%d+)"))
    return value
end

local function write_int(path, value)
    local f, err = io.open(path, "w")
    if not f then
        return false, err
    end
    local ok, werr = f:write(tostring(value))
    f:close()
    if not ok then
        return false, werr
    end
    return true
end

local function path_exists(path)
    if lfs then
        return lfs.attributes(path, "mode") ~= nil
    end
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function list_dirs(path)
    local out = {}
    if lfs then
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok then
            return out
        end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                out[#out + 1] = entry
            end
        end
    end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- root fallback ("su -c 'echo N > node'"), opt-in and always via sh
-- ---------------------------------------------------------------------------

--- Root support is NOT enabled by default: running `su` can block on a
-- permission prompt, and invoking a binary that exists but is not executable
-- aborts the VM inside the launcher's Runtime.exec wrapper (see jni.lua).
local function root_allowed()
    return G_reader_settings ~= nil and G_reader_settings:isTrue("ireader_allow_root")
end

local function root_available()
    if state.root_checked then
        return state.root_available
    end
    state.root_checked = true
    state.root_available = false

    if not root_allowed() then
        return false
    end

    for _, path in ipairs({ "/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su" }) do
        if path_exists(path) then
            -- `sh -c` keeps a missing/non-executable su from killing the VM.
            trace.step("frontlight: probing root via su")
            local res = jni.sh_status("su -c id")
            trace.step("frontlight: su result=" .. tostring(res))
            if res == 0 then
                state.root_available = true
            end
            break
        end
    end
    logger.dbg("[iReader] frontlight: root available =", tostring(state.root_available))
    return state.root_available
end

local function write_node(path, value)
    local ok, err = write_int(path, value)
    if ok then
        return true, "direct"
    end
    if root_available() then
        local res = jni.sh_status(string.format("su -c 'echo %d > %s'", value, path))
        if res == 0 then
            return true, "su"
        end
    end
    return false, tostring(err)
end

-- ---------------------------------------------------------------------------
-- backend 1: sysfs
-- ---------------------------------------------------------------------------

-- Groups are written together: on a dual-string panel this changes brightness
-- without touching the colour temperature.
local KNOWN_GROUPS = {
    {
        id = "sysfs_lm3630a",
        label = "sysfs: LM3630A (iReader)",
        dirs = { "/sys/class/backlight/lm3630a_leda", "/sys/class/backlight/lm3630a_ledb" },
    },
    {
        id = "sysfs_onyx",
        label = "sysfs: onyx_bl_br / onyx_bl_ct",
        dirs = { "/sys/class/backlight/onyx_bl_br", "/sys/class/backlight/onyx_bl_ct" },
    },
    {
        id = "sysfs_white_warm",
        label = "sysfs: white / warm",
        dirs = { "/sys/class/backlight/white", "/sys/class/backlight/warm" },
    },
    {
        id = "sysfs_rk28",
        label = "sysfs: rk28_bl / rk28_bl_warm",
        dirs = { "/sys/class/backlight/rk28_bl", "/sys/class/backlight/rk28_bl_warm" },
    },
    {
        id = "sysfs_pwm",
        label = "sysfs: pwm-backlight.0",
        dirs = { "/sys/class/backlight/pwm-backlight.0" },
    },
}

local function collect_nodes(dirs)
    local nodes = {}
    for _, dir in ipairs(dirs) do
        local brightness = dir .. "/brightness"
        if path_exists(brightness) then
            local max = read_int(dir .. "/max_brightness") or 255
            if max <= 0 then
                max = 255
            end
            nodes[#nodes + 1] = {
                dir = dir,
                brightness = brightness,
                actual = dir .. "/actual_brightness",
                max = max,
            }
        end
    end
    return nodes
end

local function sysfs_driver(id, label, dirs, note)
    local nodes = collect_nodes(dirs)
    if #nodes == 0 then
        return nil
    end

    local driver = {
        id = id,
        label = label,
        kind = "sysfs",
        nodes = nodes,
        note = note,
    }

    --- Some backlight drivers stay dark until bl_power is cleared (0 = on,
    -- 4 = off).  If the node exists and the light looks powered down, turn it on
    -- before writing brightness -- otherwise "the write worked but nothing
    -- happened" is indistinguishable from a wrong node.
    local function ensure_powered()
        for _, node in ipairs(nodes) do
            local power_path = node.dir .. "/bl_power"
            local power = read_int(power_path)
            if power ~= nil and power ~= 0 then
                trace.step("frontlight: " .. id .. " bl_power was " .. tostring(power) .. ", setting 0")
                write_node(power_path, 0)
            end
        end
    end

    --- Is the node actually writable by us (or via su)?
    function driver.check()
        local last_err
        for _, node in ipairs(nodes) do
            local current = read_int(node.actual) or read_int(node.brightness)
            if current == nil then
                -- Not readable: cannot test without changing the light, so
                -- report it as "maybe" and let the user confirm.
                return true, "unreadable, untested"
            end
            local ok, how = write_node(node.brightness, current)
            if ok then
                return true, "writable (" .. tostring(how) .. ")"
            end
            last_err = how
        end
        return false, tostring(last_err)
    end

    function driver.available()
        return #nodes > 0
    end

    function driver.get()
        for _, node in ipairs(nodes) do
            local raw = read_int(node.actual) or read_int(node.brightness)
            if raw ~= nil then
                return math.floor(raw * 100 / node.max + 0.5)
            end
        end
        return nil
    end

    function driver.set(level)
        ensure_powered()
        local any = false
        local last_err
        for _, node in ipairs(nodes) do
            local raw = math.floor(level * node.max / 100 + 0.5)
            if raw < 0 then raw = 0 end
            if raw > node.max then raw = node.max end
            local ok, err = write_node(node.brightness, raw)
            if ok then
                any = true
            else
                last_err = err
            end
        end
        return any, last_err
    end

    function driver.describe()
        local parts = {}
        for _, node in ipairs(nodes) do
            parts[#parts + 1] = string.format("%s (max %d, now %s, bl_power %s)", node.brightness,
                node.max, tostring(read_int(node.actual) or read_int(node.brightness)),
                tostring(read_int(node.dir .. "/bl_power")))
        end
        return table.concat(parts, "; ")
    end

    return driver
end

-- Include every node in /sys/class/backlight (that class is backlights by
-- definition, and driver-chip names like "ktd3136" or "lm3697" carry no useful
-- keyword), and only filter /sys/class/leds by name.
local BAD_KEYWORDS = { "keyboard", "button", "charger", "battery", "wifi", "power",
                       "touch", "cap", "flash", "notif", "ir", "bluetooth", "mmc",
                       "vibrator", "torch", "backlight_notify" }
local GOOD_KEYWORDS = { "lm3630", "bl", "light", "backlight", "led", "pwm", "warm", "white" }

local function score_name(name)
    local lower = name:lower()
    for _, bad in ipairs(BAD_KEYWORDS) do
        if lower:find(bad, 1, true) then
            return -100
        end
    end
    local score = 0
    for index, good in ipairs(GOOD_KEYWORDS) do
        if lower:find(good, 1, true) then
            score = score + (10 - index)
        end
    end
    return score
end

local function scanned_drivers(known_ids, known_dirs)
    local out = {}
    local candidates = {}
    for _, root in ipairs({ "/sys/class/backlight", "/sys/class/leds" }) do
        for _, name in ipairs(list_dirs(root)) do
            local dir = root .. "/" .. name
            if path_exists(dir .. "/brightness") and not (known_dirs and known_dirs[dir]) then
                local score = score_name(name)
                local is_backlight = root == "/sys/class/backlight"
                -- backlight nodes are kept even with a neutral score, LED nodes
                -- only when they look like a light.
                if score > -100 and (is_backlight or score > 0) then
                    candidates[#candidates + 1] = { dir = dir, score = score }
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)

    for _, candidate in ipairs(candidates) do
        local id = "sysfs_scan_" .. candidate.dir:gsub("^/sys/class/", ""):gsub("/", "_")
        if not known_ids[id] then
            local driver = sysfs_driver(id, "sysfs: " .. candidate.dir, { candidate.dir },
                "auto-detected")
            if driver then
                out[#out + 1] = driver
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- backend 2/3: Android Settings.System
-- ---------------------------------------------------------------------------

local function settings_call(jctx, class_jni, class_dot, method, key, value)
    local activity, resolver_mid = jni.activity_method(jctx, "getContentResolver",
        "()Landroid/content/ContentResolver;")
    if not resolver_mid then
        return nil, "no getContentResolver()"
    end
    local resolver = jni.call_object(jctx, activity, resolver_mid)
    if not resolver then
        return nil, "no ContentResolver"
    end

    local clazz = jni.find_class(jctx, class_jni, class_dot)
    if not clazz then
        return nil, class_dot .. " not found"
    end

    local signature, mid
    if method == "getInt" then
        signature = "(Landroid/content/ContentResolver;Ljava/lang/String;I)I"
    else
        signature = "(Landroid/content/ContentResolver;Ljava/lang/String;I)Z"
    end
    mid = jni.static_method(jctx, clazz, method, signature)
    if not mid then
        jni.free(jctx, clazz)
        return nil, method .. " not found"
    end

    local jkey = jni.new_string(jctx, key)
    local result
    if method == "getInt" then
        result = jni.call_static_int(jctx, clazz, mid, resolver, jkey, ffi.new("int32_t", 0))
    else
        result = jni.call_static_boolean(jctx, clazz, mid, resolver, jkey,
            ffi.new("int32_t", value or 0))
    end
    jni.free(jctx, jkey)
    jni.free(jctx, clazz)
    return result
end

local function settings_driver(id, label, key, note, class_jni, class_dot)
    class_jni = class_jni or "android/provider/Settings$System"
    class_dot = class_dot or "android.provider.Settings$System"

    local driver = {
        id = id,
        label = label,
        kind = "settings",
        key = key,
        note = note,
        -- screen_brightness is a 0..255 system setting on virtually every device
        max = 255,
    }

    local function read_value()
        if not jni.available() then
            return nil, "no JNI bridge"
        end
        local ran, res = jni.run(function(jctx)
            return settings_call(jctx, class_jni, class_dot, "getInt", key)
        end)
        if not ran or type(res) ~= "number" then
            return nil, tostring(res)
        end
        return res
    end

    local function write_raw(raw)
        local ran, res = jni.run(function(jctx)
            return settings_call(jctx, class_jni, class_dot, "putInt", key, raw)
        end)
        if not ran then
            return false, tostring(res)
        end
        if res ~= true then
            local extra = jni.last_exception()
            return false, "putInt returned " .. tostring(res)
                .. (extra and (" [" .. extra .. "]") or "")
        end
        -- Read back so we can tell the user when the value was not accepted.
        local after = read_value()
        if after ~= nil and math.abs(after - raw) > 2 then
            return false, string.format("write ignored (still %s)", tostring(after))
        end
        return true
    end

    function driver.available()
        return read_value() ~= nil
    end

    function driver.check()
        -- Probe writability by writing the current value back: same trick as the
        -- sysfs backend.  (Asking the launcher for WRITE_SETTINGS turned out to
        -- be an extra, less tested JNI call on a path we are debugging, and the
        -- write itself already reports failure cleanly.)
        local current = read_value()
        if current == nil then
            return false, "unreadable"
        end
        local ok, err = write_raw(current)
        if ok then
            return true, "readable and writable"
        end
        return false, "readable but not writable: " .. tostring(err)
    end

    function driver.get()
        local value = read_value()
        if value == nil then
            return nil
        end
        return math.floor(value * 100 / driver.max + 0.5)
    end

    function driver.set(level)
        return write_raw(math.floor(level * driver.max / 100 + 0.5))
    end

    function driver.describe()
        return string.format("%s[%s] = %s", class_dot, key, tostring(read_value()))
    end

    return driver
end

--- Brightness-ish Settings keys that exist on this device.
-- The frontlight of this iReader is driven from the system quick-settings
-- panel, i.e. by the framework, so the right channel is very likely a Settings
-- key -- and on some ROMs it is a vendor key rather than screen_brightness.
-- Rather than guessing, ask `settings list` what exists.
local discovered_keys = nil

-- Absolute path: the app's PATH may be too small for the `settings` wrapper,
-- which is why the earlier attempts returned 0 bytes.
local SETTINGS_BIN = "/system/bin/settings"
local DUMP_SCOPES = { "system", "global", "secure" }

--- Full dump of one Settings scope as a key -> value map (strings), or nil.
function M.dump_settings(scope)
    local out = jni.sh(SETTINGS_BIN .. " list " .. scope)
    if type(out) ~= "string" or out == "" then
        return nil
    end
    local map = {}
    for line in out:gmatch("[^%r%n]+") do
        local key, value = line:match("^([%w_%.%-]+)=(.*)$")
        if key then
            map[key] = value
        end
    end
    if next(map) == nil then
        return nil
    end
    return map
end

local function looks_like_brightness(key)
    local lower = key:lower()
    return lower:find("bright", 1, true) or lower:find("light", 1, true)
        or lower:find("led", 1, true) or lower:find("warm", 1, true)
        or lower:find("cold", 1, true)
end

function M.discover_settings_keys()
    if discovered_keys ~= nil then
        return discovered_keys
    end
    discovered_keys = {}
    if not jni.available() then
        return discovered_keys
    end
    -- Does the launcher's Runtime.exec bridge work at all?
    local ok_echo, echo = pcall(jni.sh, "echo ireader-shell-ok")
    trace.step("frontlight: shell bridge = " .. tostring(ok_echo) .. " '"
        .. tostring(echo and echo:gsub("%s+$", "") or echo) .. "'")

    for _, scope in ipairs(DUMP_SCOPES) do
        local map = M.dump_settings(scope)
        local count = 0
        if map then
            for key in pairs(map) do
                count = count + 1
                if looks_like_brightness(key) and key ~= "screen_brightness" then
                    discovered_keys[#discovered_keys + 1] = { scope = scope, key = key }
                end
            end
        end
        trace.step("frontlight: settings dump " .. scope .. " -> " .. count .. " keys"
            .. (count == 0 and " (expected: `settings` is a shell-only wrapper, apps are refused)" or ""))
    end
    trace.step("frontlight: discovered brightness keys = " .. #discovered_keys)
    return discovered_keys
end

--- Ask the OS for WRITE_SETTINGS, which the Settings backends need.
-- Implemented with our own JNI (exception-checked) rather than the launcher's
-- wrapper, because a wrapper whose Kotlin counterpart is missing aborts the VM
-- when it calls a NULL method id -- that is what killed an earlier version.
function M.request_write_settings()
    if not jni.available() then
        return false, "no JNI bridge"
    end
    trace.step("frontlight: request WRITE_SETTINGS")
    local ran, res = jni.run(function(jctx)
        local activity, pkg_mid = jni.activity_method(jctx, "getPackageName",
            "()Ljava/lang/String;")
        if pkg_mid == nil then
            return nil, "no getPackageName()"
        end
        local pkg_str = jni.call_object(jctx, activity, pkg_mid)
        local package = jni.to_string(jctx, pkg_str)
        jni.free(jctx, pkg_str)
        if package == nil then
            return nil, "no package name"
        end
        trace.step("frontlight: request WRITE_SETTINGS package=" .. package)

        local uri_class = jni.find_class(jctx, "android/net/Uri", "android.net.Uri")
        local parse = uri_class and jni.static_method(jctx, uri_class, "parse",
            "(Ljava/lang/String;)Landroid/net/Uri;")
        if parse == nil then
            return nil, "Uri.parse not found"
        end
        local uri_arg = jni.new_string(jctx, "package:" .. package)
        local uri = jni.call_static_object(jctx, uri_class, parse, uri_arg)
        jni.free(jctx, uri_arg)
        if uri == nil then
            return nil, "Uri.parse failed"
        end

        local intent_class = jni.find_class(jctx, "android/content/Intent",
            "android.content.Intent")
        local ctor = intent_class and jni.method(jctx, intent_class, "<init>",
            "(Ljava/lang/String;Landroid/net/Uri;)V")
        if ctor == nil then
            return nil, "Intent(String, Uri) not found"
        end
        -- This is a String constant in the framework, no field lookup needed.
        local action = jni.new_string(jctx, "android.settings.ACTION_MANAGE_WRITE_SETTINGS")
        local intent = jni.new_object(jctx, intent_class, ctor, action, uri)
        jni.free(jctx, action)
        if intent == nil then
            return nil, "could not build the intent"
        end

        -- FLAG_ACTIVITY_NEW_TASK (0x10000000): harmless from an Activity, and
        -- required when the framework treats us as a non-Activity caller.
        local add_flags = jni.method(jctx, intent_class, "addFlags",
            "(I)Landroid/content/Intent;")
        if add_flags ~= nil then
            local flagged = jni.call_object(jctx, intent, add_flags, ffi.new("int32_t", 0x10000000))
            if flagged ~= nil then
                intent = flagged
            end
        end

        local activity_obj, start_mid = jni.activity_method(jctx, "startActivity",
            "(Landroid/content/Intent;)V")
        if start_mid == nil then
            return nil, "no startActivity()"
        end
        if not jni.call_void(jctx, activity_obj, start_mid, intent) then
            return nil, "startActivity failed"
        end
        return true
    end)
    if not ran then
        trace.step("frontlight: request WRITE_SETTINGS -> lua error " .. tostring(res))
        return false, tostring(res)
    end
    if res ~= true then
        local reason = tostring(res)
        local extra = jni.last_exception()
        if extra then
            reason = reason .. " [" .. extra .. "]"
        end
        trace.step("frontlight: request WRITE_SETTINGS -> " .. reason)
        return false, reason
    end
    trace.step("frontlight: request WRITE_SETTINGS -> dialog opened")
    return true
end

--- Candidate keys for the "which key drives the frontlight?" learning flow.
-- Read-only on purpose: reading needs no permission at all.
M.LEARN_KEYS = {
    { scope = "system", key = "screen_brightness" },
    { scope = "system", key = "screen_brightness_float" },
    { scope = "system", key = "screen_brightness_mode" },
    { scope = "system", key = "brightness_level" },
    { scope = "system", key = "ireader_brightness" },
    { scope = "system", key = "warm_light" },
    { scope = "system", key = "cold_light" },
    { scope = "global", key = "mogu_warm_led_value" },
    { scope = "global", key = "mogu_cold_led_value" },
}

--- Read one Settings integer (no permission needed).
function M.read_setting(scope, key)
    if not jni.available() then
        return nil
    end
    local class_jni = scope == "global" and "android/provider/Settings$Global"
        or "android/provider/Settings$System"
    local class_dot = scope == "global" and "android.provider.Settings$Global"
        or "android.provider.Settings$System"
    local ran, res = jni.run(function(jctx)
        return settings_call(jctx, class_jni, class_dot, "getInt", key)
    end)
    if not ran or type(res) ~= "number" then
        return nil
    end
    return res
end

--- Snapshot *every* settings entry, so two snapshots around a user action prove
-- definitively which key (if any) the system slider writes.  Guessing key names
-- is not reliable; diffing the whole database is.
function M.sample_setting_keys()
    local out = {}
    local seen = {}
    local function add(scope, key, value)
        local id = scope .. "." .. key
        if seen[id] then
            return
        end
        seen[id] = true
        out[#out + 1] = { scope = scope, key = key, value = value }
    end

    local any_dump = false
    for _, scope in ipairs(DUMP_SCOPES) do
        local map = M.dump_settings(scope)
        if map then
            any_dump = true
            for key, value in pairs(map) do
                add(scope, key, value)
            end
        end
    end
    if not any_dump then
        -- Shell dump unavailable: fall back to reading a shortlist directly.
        for _, entry in ipairs(M.LEARN_KEYS) do
            add(entry.scope, entry.key, M.read_setting(entry.scope, entry.key))
        end
    end

    table.sort(out, function(a, b)
        return (a.scope .. "." .. a.key) < (b.scope .. "." .. b.key)
    end)
    return out
end

--- The package name to use in `adb shell appops set <pkg> WRITE_SETTINGS allow`.
function M.package_name()
    if not jni.available() then
        return nil
    end
    local ran, res = jni.run(function(jctx)
        local activity, mid = jni.activity_method(jctx, "getPackageName",
            "()Ljava/lang/String;")
        if mid == nil then
            return nil
        end
        local str = jni.call_object(jctx, activity, mid)
        local name = jni.to_string(jctx, str)
        jni.free(jctx, str)
        return name
    end)
    if not ran or type(res) ~= "string" then
        return nil
    end
    return res
end

-- ---------------------------------------------------------------------------
-- backend 4: app window brightness (always there, but cosmetic on e-ink)
-- ---------------------------------------------------------------------------

local function window_driver()
    local driver = {
        id = "window",
        label = "Android window brightness (last resort)",
        kind = "window",
        note = "only dims the app window; does not drive the LED panel",
    }

    function driver.available()
        return jni.available() and jni.android.setScreenBrightness ~= nil
    end

    function driver.check()
        return true, "always available"
    end

    function driver.get()
        if not jni.available() or not jni.android.getScreenBrightness then
            return nil
        end
        local ok, value = pcall(jni.android.getScreenBrightness)
        if not ok or type(value) ~= "number" then
            return nil
        end
        return math.floor(value * 100 / 255 + 0.5)
    end

    function driver.set(level)
        if not jni.available() or not jni.android.setScreenBrightness then
            return false, "no bridge"
        end
        -- The launcher's GenericController maps 1..255 onto window brightness.
        local raw = math.floor(level * 254 / 100 + 0.5) + 1
        if level <= 0 then raw = 1 end
        local ok, err = pcall(jni.android.setScreenBrightness, raw)
        if not ok then
            return false, tostring(err)
        end
        return true
    end

    function driver.describe()
        return "activity.window.attributes.screenBrightness"
    end

    return driver
end

-- ---------------------------------------------------------------------------
-- backend: a light command on the vendor EPDC class (experimental)
--
-- iReader has no public frontlight API, but the vendor EPDC class is reachable,
-- so if this firmware happens to expose a light/brightness command there, it is
-- by far the most likely way in.  The value range of such a command is
-- undocumented, so this backend assumes 0..255 (like every other LED node) and
-- says so in its label; the wrong range cannot break anything, it just saturates.
-- ---------------------------------------------------------------------------

local EPdcLight = nil

local function epdc_light_driver()
    if EPdcLight == nil then
        EPdcLight = {
            id = "epdc_light",
            label = "EPDC light command (experimental, 0-255)",
            kind = "epdc",
            max = 255,
            note = "vendor light/brightness method found on android.eink.EPDCDevice",
        }

        function EPdcLight.available()
            -- Probing the vendor class is the safest JNI we do (no invocation),
            -- and it is canary-armed, so this is acceptable on a user action.
            if not epdc.ensure_probed() then
                return false
            end
            return epdc.light_method() ~= nil
        end

        function EPdcLight.check()
            if not EPdcLight.available() then
                return false, "no light command on android.eink.EPDCDevice"
            end
            local current = epdc.get_light()
            if current == nil then
                -- No getter: we cannot test without changing the light, so claim
                -- it and let the wizard decide.
                return true, "no getter, untested"
            end
            local ok, err = EPdcLight.set(math.floor(current * 100 / EPdcLight.max + 0.5))
            if ok then
                return true, "writable"
            end
            return false, tostring(err)
        end

        function EPdcLight.get()
            local raw = epdc.get_light()
            if raw == nil then
                return nil
            end
            return math.floor(raw * 100 / EPdcLight.max + 0.5)
        end

        function EPdcLight.set(level)
            if not epdc.ensure_probed() then
                return false, epdc.status()
            end
            local raw = math.floor(level * EPdcLight.max / 100 + 0.5)
            return epdc.set_light(raw)
        end

        function EPdcLight.describe()
            return "EPDCDevice." .. tostring(epdc.light_method())
        end
    end
    return EPdcLight
end

-- ---------------------------------------------------------------------------
-- guarded driver access
--
-- Every interaction with a backend goes through here.  Each backend gets its
-- own crash canary, so a backend that kills the process is skipped on the next
-- start instead of being retried forever, and each interaction leaves a
-- breadcrumb naming the backend -- which is what tells us *which* call died,
-- since a native abort leaves no traceback at all.
-- ---------------------------------------------------------------------------

local function canary_key(driver)
    return "frontlight_" .. driver.id
end

function M.is_driver_disabled(driver)
    return driver ~= nil and canary.poisoned(canary_key(driver))
end

local function guarded_check(driver)
    if M.is_driver_disabled(driver) then
        return false, "disabled after a previous crash"
    end
    trace.step("frontlight: check " .. driver.id)
    canary.begin(canary_key(driver))
    local ok, writable, note = pcall(driver.check)
    canary.finish(canary_key(driver))
    if not ok then
        return false, tostring(writable)
    end
    return writable, note
end

--- Write a level through a specific backend.
-- Exposed because the detection wizard has to try backends other than the
-- active one, and that path must be guarded exactly like the normal one.
function M.safe_set(driver, level)
    if driver == nil then
        return false, "no driver"
    end
    if M.is_driver_disabled(driver) then
        return false, "disabled after a previous crash"
    end
    trace.step("frontlight: set " .. driver.id .. " = " .. tostring(level))
    canary.begin(canary_key(driver))
    local ok, result, err = pcall(driver.set, level)
    canary.finish(canary_key(driver))
    if not ok then
        trace.step("frontlight: set " .. driver.id .. " FAILED (lua error): " .. tostring(result))
        return false, tostring(result)
    end
    -- Log the outcome: "no effect" and "permission denied" look identical on the
    -- panel, and we need to tell them apart from the log.
    trace.step(string.format("frontlight: set %s -> ok=%s %s", driver.id,
        tostring(result), tostring(err or "")))
    return result, err
end

--- Forget the per-backend blacklist (diagnostics menu).
function M.clear_driver_blacklist()
    for _, driver in ipairs(M.drivers()) do
        canary.clear(canary_key(driver))
    end
    trace.step("frontlight: driver blacklist cleared")
end

-- ---------------------------------------------------------------------------
-- driver registry
-- ---------------------------------------------------------------------------

--- Build (and cache) the list of candidate backends.
function M.drivers()
    if state.drivers then
        return state.drivers
    end

    local list = {}
    local known_ids = {}
    local known_dirs = {}
    for _, group in ipairs(KNOWN_GROUPS) do
        known_ids[group.id] = true
        for _, dir in ipairs(group.dirs) do
            known_dirs[dir] = true
        end
        local driver = sysfs_driver(group.id, group.label, group.dirs, "known iReader/vendor node")
        if driver then
            list[#list + 1] = driver
        end
    end
    for _, driver in ipairs(scanned_drivers(known_ids, known_dirs)) do
        list[#list + 1] = driver
    end

    local manual = G_reader_settings and G_reader_settings:readSetting("ireader_sysfs_path")
    if manual and manual ~= "" then
        local driver = sysfs_driver("sysfs_manual", "sysfs: " .. manual, { manual }, "user supplied")
        if driver then
            -- Put the user's own choice first: they know their device.
            table.insert(list, 1, driver)
        end
    end

    -- A light command on the vendor EPDC class, when this firmware has one:
    -- on iReader that is the most likely way in, because sysfs is usually
    -- read-only for normal apps.  Unavailable (and thus skipped) otherwise.
    list[#list + 1] = epdc_light_driver()

    list[#list + 1] = settings_driver("settings_system", "Settings: screen_brightness",
        "screen_brightness", "framework brightness; needs WRITE_SETTINGS to write")

    -- Vendor brightness keys found on this ROM (bounded, so the wizard stays
    -- usable).  The frontlight here is driven by the system panel, so one of
    -- these may well be the real channel.
    local added = 0
    for _, entry in ipairs(M.discover_settings_keys()) do
        if added >= 4 then
            break
        end
        local id = "settings_" .. entry.scope .. "_" .. entry.key:gsub("[^%w]", "_")
        local label = string.format("Settings.%s: %s",
            entry.scope == "global" and "Global" or "System", entry.key)
        local class_jni = entry.scope == "global" and "android/provider/Settings$Global"
            or "android/provider/Settings$System"
        local class_dot = entry.scope == "global" and "android.provider.Settings$Global"
            or "android.provider.Settings$System"
        list[#list + 1] = settings_driver(id, label, entry.key, "auto-discovered key",
            class_jni, class_dot)
        added = added + 1
    end

    local vendor_key = G_reader_settings and G_reader_settings:readSetting("ireader_settings_key")
    if vendor_key and vendor_key ~= "" and vendor_key ~= "screen_brightness" then
        list[#list + 1] = settings_driver("settings_vendor", "Settings: " .. vendor_key,
            vendor_key, "user supplied vendor key")
    end

    list[#list + 1] = window_driver()

    state.drivers = list
    return list
end

function M.invalidate()
    state.drivers = nil
end

function M.find(id)
    for _, driver in ipairs(M.drivers()) do
        if driver.id == id then
            return driver
        end
    end
    return nil
end

--- The driver that is actually in use ("auto" resolves to the first workable one).
-- The result is cached: `check()` may write to sysfs, and get()/set() are
-- called on every frontlight widget refresh.
function M.active()
    if state.active_resolved then
        return state.active_driver
    end

    -- Resolving a backend is the first thing that writes to hardware/framework,
    -- and a bad backend can take the process down: arm the canary around it, so
    -- a crash here disables this feature on the next start instead of looping.
    if canary.poisoned("frontlight") then
        state.active_resolved = true
        state.active_driver = nil
        logger.warn("[iReader] frontlight disabled: a previous session crashed while resolving a backend")
        return nil
    end

    state.active_resolved = true
    state.active_driver = nil
    trace.step("frontlight: resolving backend (canary armed)")
    canary.begin("frontlight")
    local resolved = M.resolve_active()
    canary.finish("frontlight")
    state.active_driver = resolved
    trace.step("frontlight: backend = " .. (resolved and resolved.id or "none"))
    return resolved
end

--- The actual backend resolution (kept separate so M.active() can guard it).
function M.resolve_active()
    local configured = G_reader_settings and G_reader_settings:readSetting("ireader_frontlight_driver")
    if configured and configured ~= "auto" then
        local driver = M.find(configured)
        if driver and not M.is_driver_disabled(driver) then
            return driver
        end
    end

    -- "auto": first backend that both exists and is verifiably writable.
    for _, driver in ipairs(M.drivers()) do
        if driver.available() and not M.is_driver_disabled(driver) then
            local ok = guarded_check(driver)
            if ok then
                return driver
            end
        end
    end

    -- Nothing writable (typical on a locked-down iReader): fall back to
    -- whatever exists so that the UI at least has *something* to drive.
    for _, driver in ipairs(M.drivers()) do
        if driver.available() and not M.is_driver_disabled(driver) then
            return driver
        end
    end
    return nil
end

--- Candidate list for the confirmation wizard: only backends that exist.
function M.candidates()
    local out = {}
    for _, driver in ipairs(M.drivers()) do
        local disabled = M.is_driver_disabled(driver)
        local ok = driver.available()
        local writable, note = false, nil
        if ok and not disabled then
            writable, note = guarded_check(driver)
        elseif disabled then
            note = "disabled: it crashed a previous session"
        end
        out[#out + 1] = {
            driver = driver,
            available = ok,
            writable = writable,
            disabled = disabled,
            note = note,
        }
    end
    return out
end

--- Same, but without writing anything: `check()` probes writability by writing
-- the current value back, which is a hardware/framework interaction we do not
-- want to trigger merely to draw a menu.
function M.readonly_candidates()
    local out = {}
    for _, driver in ipairs(M.drivers()) do
        local disabled = M.is_driver_disabled(driver)
        local available = false
        if not disabled then
            local ok, res = pcall(driver.available)
            available = ok and res == true
        end
        out[#out + 1] = {
            driver = driver,
            available = available,
            writable = false,
            disabled = disabled,
            note = disabled and "disabled: it crashed a previous session" or nil,
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- public level API (KOReader scale, 0..100)
-- ---------------------------------------------------------------------------

function M.get()
    local driver = M.active()
    if driver then
        if not state.first_read_done then
            -- Reads can be fatal too (they go through the same JNI bridge), so
            -- the first one is guarded and named in the breadcrumbs.
            state.first_read_done = true
            trace.step("frontlight: first read via " .. driver.id)
            canary.begin(canary_key(driver))
            local ok, level = pcall(driver.get)
            canary.finish(canary_key(driver))
            if ok and type(level) == "number" then
                return level
            end
            return state.level or 0
        end
        local level = driver.get()
        if level ~= nil then
            return level
        end
    end
    return state.level or 0
end

function M.set(level)
    if type(level) ~= "number" then
        return false
    end
    if level < 0 then level = 0 elseif level > 100 then level = 100 end

    local driver = M.active()
    if not driver then
        return false, "no frontlight backend found"
    end

    local ok, err = M.safe_set(driver, level)
    if ok then
        state.level = level
        state.first_write_done = true
    else
        state.notes[driver.id] = tostring(err)
    end
    return ok, err
end

--- Forget a poisoning of the frontlight path (diagnostics menu).
function M.reset()
    canary.clear("frontlight")
    state.active_resolved = false
    state.active_driver = nil
    state.first_write_done = false
    state.first_read_done = false
    state.root_checked = false
    state.root_available = false
    M.invalidate()
    logger.info("[iReader] frontlight state reset")
end

--- Is any single backend blacklisted after a crash?
function M.has_blacklisted_drivers()
    for _, driver in ipairs(M.drivers()) do
        if M.is_driver_disabled(driver) then
            return true
        end
    end
    return false
end

function M.driver_label()
    local driver = M.active()
    if not driver then
        return "none"
    end
    return driver.label
end

-- ---------------------------------------------------------------------------
-- KOReader PowerD integration
-- ---------------------------------------------------------------------------

--- Take over the frontlight from KOReader's Android PowerD.
-- @tparam table Device the KOReader device singleton
function M.install(Device)
    if state.installed then
        return true
    end
    if not Device then
        return false
    end
    local powerd = Device.powerd or (Device.getPowerDevice and Device:getPowerDevice())
    if not powerd then
        logger.warn("[iReader] frontlight: no PowerD instance")
        return false
    end

    state.Device = Device
    state.powerd = powerd

    local saved = {
        hasFrontlight = Device.hasFrontlight,
        showLightDialog = Device.showLightDialog,
    }
    saved.powerd = {
        setIntensityHW = powerd.setIntensityHW,
        frontlightIntensityHW = powerd.frontlightIntensityHW,
        isFrontlightOnHW = powerd.isFrontlightOnHW,
        turnOffFrontlightHW = powerd.turnOffFrontlightHW,
        turnOnFrontlightHW = powerd.turnOnFrontlightHW,
    }
    state.saved = saved
    state.installed = true

    -- Capability flag: on iReader the launcher already reports lights (an
    -- unknown model is not in its QUIRK_NO_LIGHTS list), but keep the override
    -- for firmware/launcher combinations that report none.
    -- NOTE: this is the only JNI-touching call on the startup path, and it is
    -- the very same call KOReader itself makes in BasePowerD:new() at every
    -- launch, so it is a proven-safe code path.
    if not Device:hasFrontlight() then
        Device.hasFrontlight = function() return true end
    end

    -- Use a clean 0..100 scale (AndroidPowerD:init() had rescaled fl_min based
    -- on the launcher's generic controller, which we do not use any more).
    powerd.fl_min = 0
    powerd.fl_max = 100

    function powerd:frontlightIntensityHW()
        local level = M.get()
        if type(level) == "number" then
            return level
        end
        return self.fl_intensity or 0
    end

    function powerd:setIntensityHW(intensity)
        self.fl_intensity = intensity
        M.set(intensity)
        self:_decideFrontlightState()
    end

    function powerd:isFrontlightOnHW()
        local level = M.get()
        if type(level) == "number" then
            return level > 0
        end
        return (self.fl_intensity or 0) > 0
    end

    function powerd:turnOffFrontlightHW()
        M.set(0)
    end

    function powerd:turnOnFrontlightHW(done_callback)
        if done_callback then
            done_callback()
        end
        M.set(self.fl_intensity and self.fl_intensity > 0 and self.fl_intensity or DEFAULT_LEVEL)
        return false
    end

    -- Android normally opens a native Java dialog that drives the launcher's
    -- GenericController; that cannot reach iReader's LED driver, so use
    -- KOReader's own frontlight widget (which goes through PowerD above).
    Device.showLightDialog = function(self)
        local UIManager = require("ui/uimanager")
        local FrontLightWidget = require("ui/widget/frontlightwidget")
        UIManager:show(FrontLightWidget:new{})
    end

    -- NOTE: deliberately do NOT touch any backend here.  Installing the hooks
    -- only patches methods; the backend is resolved lazily on the first read or
    -- write (i.e. when you open the frontlight panel or use a gesture), which
    -- keeps startup free of JNI/sysfs/subprocess work.  If a backend turns out
    -- to be fatal, the canary in M.active() disables it on the next start
    -- instead of crash-looping at launch.
    logger.info("[iReader] frontlight hooks installed (backend resolved on first use)")
    trace.step("frontlight: hooks installed")
    return true
end

--- Give the frontlight back to KOReader's stock Android implementation.
function M.uninstall()
    if not state.installed then
        return false
    end
    local Device, powerd, saved = state.Device, state.powerd, state.saved
    if Device and saved then
        Device.hasFrontlight = saved.hasFrontlight
        Device.showLightDialog = saved.showLightDialog
    end
    if powerd and saved then
        for key, value in pairs(saved.powerd) do
            powerd[key] = value
        end
    end
    state.installed = false
    state.Device = nil
    state.powerd = nil
    state.saved = nil
    logger.info("[iReader] frontlight backend released")
    return true
end

function M.is_installed()
    return state.installed
end

--- Was this feature disabled because a previous session crashed while using it?
function M.is_poisoned()
    return canary.poisoned("frontlight")
end

--- Diagnostic report for the settings menu / probe log.
function M.report()
    local lines = { "== Frontlight ==" }
    lines[#lines + 1] = "installed: " .. tostring(state.installed)
    lines[#lines + 1] = "disabled after a previous crash: " .. tostring(M.is_poisoned())
    lines[#lines + 1] = "active backend: " .. M.driver_label()
    lines[#lines + 1] = "last level set: " .. tostring(state.level)
    if jni.android and jni.android.canWriteSettings then
        local ok, granted = pcall(jni.android.canWriteSettings)
        lines[#lines + 1] = "WRITE_SETTINGS granted: " .. tostring(ok and granted or false)
    end
    lines[#lines + 1] = "root (su): " .. tostring(root_available())
    lines[#lines + 1] = "package name (for adb): " .. tostring(M.package_name())
    lines[#lines + 1] = "settings keys:"
    for _, entry in ipairs(M.sample_setting_keys()) do
        lines[#lines + 1] = string.format("  %s.%s = %s", entry.scope, entry.key,
            tostring(entry.value))
    end
    lines[#lines + 1] = "candidates:"
    for _, candidate in ipairs(M.candidates()) do
        lines[#lines + 1] = string.format("  [%s] %s | available=%s writable=%s disabled=%s | %s",
            candidate.driver.kind, candidate.driver.label, tostring(candidate.available),
            tostring(candidate.writable), tostring(candidate.disabled), tostring(candidate.note))
        if candidate.driver.describe then
            lines[#lines + 1] = "      " .. candidate.driver.describe()
        end
    end
    if next(state.notes) then
        lines[#lines + 1] = "write errors:"
        for id, note in pairs(state.notes) do
            lines[#lines + 1] = "  " .. id .. ": " .. note
        end
    end

    -- Conclusion: "node exists but Permission denied" and "node missing" need
    -- completely different fixes, and the panel looks identical either way.
    local denied, missing = false, false
    for _, note in pairs(state.notes) do
        local text = tostring(note)
        if text:find("Permission denied", 1, true) then
            denied = true
        elseif text:find("No such file", 1, true) then
            missing = true
        end
    end
    lines[#lines + 1] = "conclusion:"
    if denied then
        lines[#lines + 1] = "  the LED nodes EXIST but a normal app may not write them (Permission denied)"
        lines[#lines + 1] = "  measured on this device: no Settings key follows the system brightness"
        lines[#lines + 1] = "  slider, the vendor EPDC class has no light method, the window attribute"
        lines[#lines + 1] = "  does nothing, and `settings list` is refused to apps -> there is no"
        lines[#lines + 1] = "  app-accessible frontlight channel on this firmware."
        lines[#lines + 1] = "  -> root is required: enable \"Allow root (su) for the frontlight\""
    elseif missing then
        lines[#lines + 1] = "  no writable LED node found"
    else
        lines[#lines + 1] = "  nothing conclusive; see the notes above"
    end
    local extra = jni.last_exception()
    if extra then
        lines[#lines + 1] = "last Java exception: " .. extra
    end
    return table.concat(lines, "\n")
end

return M
