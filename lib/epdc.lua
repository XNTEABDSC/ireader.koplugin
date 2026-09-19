--[[--
EPDC ("electronic paper display controller") bridge for 掌阅 (iReader) devices
running SmartOS 4.x.

What the vendor interface does
------------------------------
The vendor framework class `android.eink.EPDCDevice` exposes a command channel
that arms the water-ripple page-turn animation for the *next* frame posted to
the display controller.  On the devices the community has reverse engineered so
far it looks like:

    EPDCDevice.nativePostCommand("next-effect-type " .. effect)
    EPDCDevice.setForceNextPostMode(0x01000063)

`effect` is a bit field: `direction | speed_flag`

    direction (depends on the current Surface rotation, 0..3):
        forward : { 1, 4, 2, 3 }
        backward: { 2, 3, 1, 4 }
    speed flag:
        slow = 128, standard = 64, fast = 0

Direction tables and speed flags come from the two reference implementations
that already drive this interface:

  * legadoM-Ink, app/src/main/java/io/legado/app/lib/eink/IReaderPageH.kt
  * Shihon,  app/src/main/java/eu/kanade/tachiyomi/util/system/SmartOsPageTurnEffect.kt
    (WaterRippleSpeed: SLOW=128, STANDARD=64, FAST=0)

Why there is discovery code in here
-----------------------------------
On some firmware (reported on iReader Air3 Pro / SmartOS 4.0.1) the class exists
but does **not** declare `nativePostCommand(String)` with that exact name or
signature.  Hardcoding it therefore fails with "method not found".

So the bridge works in two stages:

  1. try the known exact signature (cheap, no reflection);
  2. otherwise enumerate the class with Java reflection, pick the method by
     *shape* (name hints + parameter types) instead of by exact name, and log
     the real method list so the right one can be pinned down permanently.

Static and instance methods are both supported (an instance method is bound to
a singleton obtained from a static no-argument getter), and the call is
dispatched according to the method's real return type, because calling a
non-void method through CallStaticVoidMethod is undefined behaviour.

Safety
------
Nothing runs at plugin load or init time: `probe()` is called lazily (first
page turn, or an explicit menu action) and is armed with the crash canary.

@module ireader.epdc
]]

local ffi = require("ffi")
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
local trace = sibling("trace")

local M = {}

local CLASS_JNI = "android/eink/EPDCDevice"
local CLASS_DOT = "android.eink.EPDCDevice"
local CLASS_DESC = "Landroid/eink/EPDCDevice;"
local CANARY = "epdc"

-- Configuration (can be overridden from the settings menu / diagnostics).
M.config = {
    -- Force the next post into page-turn mode.
    use_force_mode = true,
    force_mode = 0x01000063,
    -- Direction code per rotation mode, indexed by KOReader's rotation mode
    -- (which matches the Android Surface rotation on this device):
    --   0 = PORTRAIT, 1 = LANDSCAPE, 2 = REVERSE_PORTRAIT, 3 = REVERSE_LANDSCAPE
    --
    -- The community reference tables (legadoM-Ink) give { 1, 4, 2, 3 } / { 2, 3, 1, 4 },
    -- but on iReader Air3 Pro that sweeps the wrong way in BOTH landscape
    -- rotations (verified on device): portrait was correct, landscape mirrored.
    -- Hence the two landscape entries are swapped here.  If another model turns
    -- out mirrored, swap the entries for modes 1 and 3 (and/or 0 and 2).
    directions_forward = { 1, 3, 2, 4 },
    directions_backward = { 2, 4, 1, 3 },
    -- Speed flags OR'ed into the direction code.
    speed_flags = { slow = 128, standard = 64, fast = 0 },
    -- Discovery hints (lowercase substrings, matched against method names).
    post_name_hints = { "postcommand", "post" },
    force_name_hints = { "force" },
}

local state = {
    probed = false,
    available = false,
    poisoned = false,
    reason = nil,
    class_ref = nil,          -- JNI global ref to the class
    methods = nil,            -- structured method list (diagnostics + discovery)
    post = nil,               -- { kind, id, ret, target }
    force = nil,              -- { kind, id, ret, target }
    light_set = nil,          -- optional vendor light command
    light_get = nil,          -- optional vendor light getter
    last_effect = nil,
    last_error = nil,
}

if canary.poisoned(CANARY) then
    state.poisoned = true
    state.probed = true
    logger.warn("[iReader] EPDC disabled: a previous session crashed while probing it")
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function format_method(method)
    return string.format("%s %s%s", method.static and "static" or "instance",
        method.name, method.signature)
end

--- Compact one-line summary of a method list, for the on-screen error message.
local function summary(methods, limit)
    if not methods or #methods == 0 then
        return "(no methods)"
    end
    local parts = {}
    for index = 1, math.min(#methods, limit or 8) do
        parts[#parts + 1] = methods[index].name .. methods[index].signature
    end
    if #methods > (limit or 8) then
        parts[#parts + 1] = "... (+" .. (#methods - (limit or 8)) .. ")"
    end
    return table.concat(parts, ", ")
end

--- Pick the first method matching `predicate`, preferring static ones.
local function pick(methods, predicate)
    local fallback
    for _, method in ipairs(methods or {}) do
        if predicate(method) then
            if method.static then
                return method
            end
            fallback = fallback or method
        end
    end
    return fallback
end

local function name_has(name, hints)
    local lower = name:lower()
    for _, hint in ipairs(hints) do
        if lower:find(hint, 1, true) then
            return true
        end
    end
    return false
end

--- Find a static no-argument getter that returns the vendor class itself, so an
-- instance method can be bound to it (e.g. `getInstance()`).
local function resolve_instance(jctx, clazz, methods)
    local candidates = {}
    for _, method in ipairs(methods or {}) do
        if method.static and #method.params == 0 and method.ret == CLASS_DESC then
            candidates[#candidates + 1] = method
        end
    end
    -- Prefer something that looks like a singleton accessor.
    table.sort(candidates, function(a, b)
        local function score(m)
            local lower = m.name:lower()
            if lower:find("getinstance", 1, true) then return 1 end
            if lower:find("instance", 1, true) then return 2 end
            if lower:find("get", 1, true) then return 3 end
            return 4
        end
        return score(a) < score(b)
    end)

    for _, method in ipairs(candidates) do
        local id = jni.static_method(jctx, clazz, method.name, method.signature)
        if id then
            local instance = jni.call_static_object(jctx, clazz, id)
            if instance ~= nil then
                local ref = jni.global_ref(jctx, instance)
                if ref ~= nil then
                    trace.step("epdc: bound instance via " .. method.name .. "()")
                    return ref
                end
            end
        end
    end
    return nil
end

--- Turn a discovered method into something callable.
-- @treturn table|nil { kind = "static"|"instance", id, ret, target }
local function bind_method(jctx, clazz, method, methods)
    if method == nil then
        return nil
    end
    local call = { kind = method.static and "static" or "instance", ret = method.ret }
    if method.static then
        call.target = state.class_ref
        call.id = jni.static_method(jctx, clazz, method.name, method.signature)
    else
        local instance = resolve_instance(jctx, clazz, methods)
        if instance == nil then
            return nil, "method is an instance method and no singleton getter was found"
        end
        call.target = instance
        call.id = jni.method(jctx, clazz, method.name, method.signature)
    end
    if call.id == nil then
        return nil, "could not resolve " .. method.name .. method.signature
    end
    return call
end

--- Invoke a bound method, dispatching on its real return type.
-- Passing a non-void method through CallStaticVoidMethod would be undefined
-- behaviour, so the return descriptor decides which JNI entry point is used.
-- @tparam table call bound method
-- @tparam string|nil str_arg argument marshalled as a jstring inside the context
-- @tparam cdata|nil int_arg argument marshalled as an int32_t
local function invoke(call, str_arg, int_arg)
    if call == nil or call.id == nil then
        return false
    end
    local ran, ok = jni.run(function(jctx)
        local args = {}
        local string_ref
        if str_arg ~= nil then
            string_ref = jni.new_string(jctx, str_arg)
            args[1] = string_ref
        elseif int_arg ~= nil then
            args[1] = int_arg
        end

        local target, id, ret = call.target, call.id, call.ret
        local is_static = call.kind == "static"
        local result
        if ret == "V" then
            if is_static then
                result = jni.call_static_void(jctx, target, id, unpack(args))
            else
                result = jni.call_void(jctx, target, id, unpack(args))
            end
        elseif ret == "I" then
            if is_static then
                result = jni.call_static_int(jctx, target, id, unpack(args)) ~= nil
            else
                result = jni.call_int(jctx, target, id, unpack(args)) ~= nil
            end
        elseif ret == "Z" then
            if is_static then
                result = jni.call_static_boolean(jctx, target, id, unpack(args)) ~= nil
            else
                result = jni.call_boolean(jctx, target, id, unpack(args)) ~= nil
            end
        else
            if is_static then
                result = jni.call_static_object(jctx, target, id, unpack(args)) ~= nil
            else
                result = jni.call_object(jctx, target, id, unpack(args)) ~= nil
            end
        end

        if string_ref ~= nil then
            jni.free(jctx, string_ref)
        end
        return result
    end)
    if not ran then
        state.last_error = tostring(ok)
        return false
    end
    return ok == true
end

-- ---------------------------------------------------------------------------
-- probing
-- ---------------------------------------------------------------------------

function M.status()
    if state.poisoned then
        return "EPDC: disabled after a crash during probing (re-enable it from Diagnostics)"
    end
    if not state.probed then
        return "EPDC: not probed yet (probe runs on the first page turn)"
    end
    if not state.available then
        return "EPDC: unavailable (" .. tostring(state.reason) .. ")"
    end
    local parts = { "EPDC: available" }
    if state.post then
        parts[#parts + 1] = "post=" .. tostring(state.post.name) .. state.post.type_signature
    end
    if state.force then
        parts[#parts + 1] = "force=" .. tostring(state.force.name) .. state.force.type_signature
    end
    if state.last_effect then
        parts[#parts + 1] = "last-effect=" .. tostring(state.last_effect)
    end
    if state.light_set then
        parts[#parts + 1] = "light=" .. tostring(state.light_set.name) .. state.light_set.type_signature
    end
    return table.concat(parts, ", ")
end

--- Name/signature of a vendor light command found on the class, if any.
function M.light_method()
    if state.light_set == nil then
        return nil
    end
    return state.light_set.name .. state.light_set.type_signature
end

--- Write the frontlight through the vendor class.
-- The value range of that command is undocumented, the caller decides the scale.
function M.set_light(raw)
    if state.light_set == nil then
        return false, "no light method on the vendor class"
    end
    return invoke(state.light_set, nil, ffi.new("int32_t", raw))
end

--- Read the frontlight through the vendor class, if it has a suitable getter.
function M.get_light()
    if state.light_get == nil then
        return nil
    end
    local ran, res = jni.run(function(jctx)
        local target, id = state.light_get.target, state.light_get.id
        if state.light_get.kind == "static" then
            return jni.call_static_int(jctx, target, id)
        end
        return jni.call_int(jctx, target, id)
    end)
    if not ran or type(res) ~= "number" then
        return nil
    end
    return res
end

function M.is_available()
    return state.available
end

function M.is_poisoned()
    return state.poisoned
end

function M.last_error()
    return state.last_error
end

--- Resolve the vendor command channel.  Idempotent; cheap after the first call.
-- @treturn boolean available
function M.probe()
    if state.probed then
        return state.available
    end
    state.probed = true
    state.available = false

    if state.poisoned then
        state.reason = "disabled after a previous crash"
        return false
    end

    if not jni.available() then
        state.reason = "no JNI bridge (this KOReader build is not the Android one)"
        logger.dbg("[iReader] EPDC:", state.reason)
        return false
    end

    trace.step("epdc: probe begin (canary armed)")
    canary.begin(CANARY)
    local ran, res = jni.run(function(jctx)
        local clazz = jni.find_class(jctx, CLASS_JNI, CLASS_DOT)
        if clazz == nil then
            return nil
        end

        local class_ref = jni.global_ref(jctx, clazz)
        state.class_ref = class_ref

        local post, force

        -- 1. The documented shape, tried first because it needs no reflection.
        local exact = jni.static_method(jctx, clazz, "nativePostCommand", "(Ljava/lang/String;)V")
        if exact ~= nil then
            post = { kind = "static", id = exact, ret = "V", target = class_ref,
                     name = "nativePostCommand", type_signature = "(String)V" }
        end
        local exact_force = jni.static_method(jctx, clazz, "setForceNextPostMode", "(I)V")
        if exact_force ~= nil then
            force = { kind = "static", id = exact_force, ret = "V", target = class_ref,
                      name = "setForceNextPostMode", type_signature = "(int)V" }
        end

        -- 2. Otherwise ask the class what it actually offers.
        local methods = jni.describe_class_methods(jctx, clazz)
        state.methods = methods

        if post == nil and methods then
            local method = pick(methods, function(m)
                return name_has(m.name, M.config.post_name_hints)
                    and #m.params == 1 and m.params[1] == "Ljava/lang/String;"
            end)
            if method then
                local call, err = bind_method(jctx, clazz, method, methods)
                if call then
                    call.name = method.name
                    call.type_signature = method.signature
                    post = call
                    trace.step("epdc: discovered post method " .. format_method(method))
                else
                    trace.step("epdc: cannot bind post method: " .. tostring(err))
                end
            end
        end

        if force == nil and methods then
            local method = pick(methods, function(m)
                return name_has(m.name, M.config.force_name_hints)
                    and #m.params == 1 and m.params[1] == "I"
            end)
            if method then
                local call = bind_method(jctx, clazz, method, methods)
                if call then
                    call.name = method.name
                    call.type_signature = method.signature
                    force = call
                    trace.step("epdc: discovered force method " .. format_method(method))
                end
            end
        end

        -- Opportunistic: some firmware exposes the panel light through the same
        -- vendor class.  If it does, it becomes an extra frontlight backend.
        local light_set, light_get
        if methods then
            local setter = pick(methods, function(m)
                local lower = m.name:lower()
                return #m.params == 1 and m.params[1] == "I"
                    and (lower:find("light", 1, true) or lower:find("bright", 1, true))
            end)
            if setter then
                local call = bind_method(jctx, clazz, setter, methods)
                if call then
                    call.name = setter.name
                    call.type_signature = setter.signature
                    light_set = call
                    trace.step("epdc: light setter " .. format_method(setter))
                end
            end

            local getter = pick(methods, function(m)
                local lower = m.name:lower()
                return #m.params == 0 and m.ret == "I"
                    and (lower:find("light", 1, true) or lower:find("bright", 1, true))
                    and (lower:find("get", 1, true) or lower:find("current", 1, true))
            end)
            if getter then
                local call = bind_method(jctx, clazz, getter, methods)
                if call then
                    call.name = getter.name
                    call.type_signature = getter.signature
                    light_get = call
                    trace.step("epdc: light getter " .. format_method(getter))
                end
            end
        end

        jni.free(jctx, clazz)
        return { post = post, force = force, methods = methods,
                 light_set = light_set, light_get = light_get }
    end)
    canary.finish(CANARY)

    if not ran then
        state.reason = "JNI call failed: " .. tostring(res)
        trace.step("epdc: JNI call failed: " .. tostring(res))
        logger.info("[iReader] EPDC:", state.reason)
        return false
    end
    if type(res) ~= "table" then
        state.reason = "class " .. CLASS_DOT .. " not found"
        trace.step("epdc: class not found")
        logger.info("[iReader] EPDC:", state.reason)
        return false
    end

    state.methods = res.methods
    state.post = res.post
    state.force = res.force
    state.light_set = res.light_set
    state.light_get = res.light_get

    if state.post == nil then
        state.reason = "no post-command method found; class declares: " .. summary(state.methods, 8)
        trace.step("epdc: methods: " .. summary(state.methods, 20))
        logger.info("[iReader] EPDC:", state.reason)
        return false
    end

    state.available = true
    state.reason = nil
    trace.step("epdc: ready via " .. tostring(state.post.name) .. tostring(state.post.type_signature))
    logger.info("[iReader] EPDC bridge ready via " .. tostring(state.post.name))
    return true
end

--- Probe at most once per session; never probes again after a poisoning.
function M.ensure_probed()
    if state.probed or state.poisoned then
        return state.available
    end
    return M.probe()
end

--- Forget a poisoning and allow probing again (diagnostics menu).
function M.reset()
    canary.clear(CANARY)
    state.poisoned = false
    state.probed = false
    state.available = false
    state.reason = nil
    state.class_ref = nil
    state.methods = nil
    state.post = nil
    state.force = nil
    state.light_set = nil
    state.light_get = nil
    logger.info("[iReader] EPDC state reset")
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

--- Raw command post. `cmd` is the full EPDC command string.
function M.post_command(cmd)
    if not state.available or state.post == nil then
        return false
    end
    return invoke(state.post, cmd, nil)
end

function M.set_force_next_post_mode(mode)
    if not state.available or state.force == nil then
        return false
    end
    return invoke(state.force, nil, ffi.new("int32_t", mode))
end

local function rotation_mode()
    -- package.loaded first: never trigger a load from the page-turn hot path.
    local Device = package.loaded["device"]
    if Device == nil then
        local ok, module = pcall(require, "device")
        if ok then
            Device = module
        end
    end
    if Device and Device.screen and Device.screen.getRotationMode then
        local ok2, rot = pcall(function() return Device.screen:getRotationMode() end)
        if ok2 and type(rot) == "number" then
            return rot % 4
        end
    end
    return 0
end

--- Compute the EPDC effect code for a page turn.
-- @tparam boolean forward true for a forward page turn
-- @tparam string speed "slow" | "standard" | "fast"
-- @treturn number effect code
function M.page_turn_effect(forward, speed)
    local dirs = forward and M.config.directions_forward or M.config.directions_backward
    local dir = dirs[(rotation_mode() or 0) + 1] or dirs[1] or 1
    local flag = M.config.speed_flags[speed] or M.config.speed_flags.standard or 0
    -- direction and speed flag never share a bit, so + is the same as bor().
    return dir + flag
end

--- Arm the ripple for the next framebuffer post.
-- @treturn boolean ok
-- @treturn number|nil effect code
function M.apply_page_turn(forward, speed)
    if not state.available then
        return false
    end
    local effect = M.page_turn_effect(forward, speed)
    state.last_effect = effect
    local ok = M.post_command("next-effect-type " .. effect)
    if ok and M.config.use_force_mode and state.force then
        M.set_force_next_post_mode(M.config.force_mode)
    end
    return ok, effect
end

--- Diagnostic text: what the vendor class actually declares.
-- @treturn table|nil array of strings
function M.describe_class()
    if state.methods then
        local out = {}
        for _, method in ipairs(state.methods) do
            out[#out + 1] = format_method(method)
        end
        return out
    end

    if not jni.available() then
        return nil, "no JNI bridge"
    end
    canary.begin(CANARY)
    local ran, res = jni.run(function(jctx)
        local clazz = jni.find_class(jctx, CLASS_JNI, CLASS_DOT)
        if clazz == nil then
            return nil
        end
        local methods = jni.describe_class_methods(jctx, clazz)
        jni.free(jctx, clazz)
        return methods
    end)
    canary.finish(CANARY)
    if not ran then
        return nil, tostring(res)
    end
    if res == nil then
        return nil, "class not found"
    end

    local out = {}
    for _, method in ipairs(res) do
        out[#out + 1] = format_method(method)
    end
    return out
end

return M
