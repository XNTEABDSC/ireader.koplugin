--[[--
Thin JNI helpers on top of the android-luajit-launcher "android" module.

Why this file exists:
  * `android.jni:callStaticVoidMethod()` is BROKEN in current launcher master
    (its body calls the non-existent lowercase `callStaticVoidMethod` field of
    the JNIEnv struct).  Everything whose Java signature returns void therefore
    has to go through the raw JNIEnv function table, which is what we do here.
  * We need to resolve Java classes that may not be visible to the boot class
    loader, and we need exception-safe probing (a pending Java exception left
    behind would corrupt every following JNI call).

Everything in here is defensive: no call ever raises, all of them report
success/failure, and every failure clears the pending Java exception.

@module ireader.jni
]]

local ffi = require("ffi")

local ok_android, android = pcall(require, "android")
if not ok_android then
    android = nil
end

local M = {}

M.android = android

-- JNI_TRUE is fixed at 1 by the JNI specification.
local JNI_TRUE = 1

-- Text of the last Java exception cleared (diagnostics).
local last_exception = nil

--- Is the launcher JNI bridge usable at all?
function M.available()
    return android ~= nil
        and android.jni ~= nil
        and android.app ~= nil
        and android.app.activity ~= nil
        and android.app.activity.vm ~= nil
end

--- Run `fn(jni)` inside an attached JNI context.
-- @treturn boolean ok
-- @return the first value returned by `fn`, or an error string
function M.run(fn)
    if not M.available() then
        return false, "android module unavailable"
    end
    local ok, res = pcall(function()
        return android.jni:context(android.app.activity.vm, function(jctx)
            -- JNI hygiene: the launcher's own wrappers (setScreenBrightness,
            -- enableFrontlightSwitch, ...) never check for a pending Java
            -- exception, and *with* one pending almost every JNI call is
            -- undefined -- FindClass() in particular just returns NULL.  That
            -- is how a failed launcher call can make a later, unrelated class
            -- lookup fail ("class not found").  So: start clean, leave clean.
            M.exception_clear_silent(jctx)
            local result = { fn(jctx) }
            M.exception_clear(jctx)
            return unpack(result)
        end)
    end)
    if not ok then
        return false, tostring(res)
    end
    return true, res
end

--- Clear a pending Java exception, recording its text first.
-- ORDER MATTERS: with an exception pending, almost every JNI function is
-- undefined behaviour (and can abort the VM).  Only ExceptionOccurred may be
-- called while it is pending, so: grab the throwable, CLEAR, and only then
-- inspect the throwable.  Getting this wrong is what made the EPDC probe crash
-- the whole process.
function M.exception_clear(jni)
    if jni == nil or jni.env == nil then
        return
    end
    if jni.env[0].ExceptionCheck(jni.env) ~= JNI_TRUE then
        return
    end

    local throwable = jni.env[0].ExceptionOccurred(jni.env)
    jni.env[0].ExceptionClear(jni.env)      -- safe from here on

    local text
    if throwable ~= nil then
        local throwable_class = jni.env[0].GetObjectClass(jni.env, throwable)
        local to_string_id = M.method(jni, throwable_class, "toString", "()Ljava/lang/String;")
        jni.env[0].DeleteLocalRef(jni.env, throwable_class)
        if to_string_id ~= nil then
            local str = M.call_object(jni, throwable, to_string_id)
            text = M.to_string(jni, str)
            M.free(jni, str)
        end
        jni.env[0].DeleteLocalRef(jni.env, throwable)
    end
    last_exception = text or "unknown Java exception"
end

--- Clear any leftover exception without recording it (used before our own calls,
-- so that a stale exception from the launcher is not reported as ours).
function M.exception_clear_silent(jni)
    if jni ~= nil and jni.env ~= nil then
        jni.env[0].ExceptionClear(jni.env)
    end
end

--- Text of the last Java exception we cleared, if any.
function M.last_exception()
    return last_exception
end

function M.exception_pending(jni)
    return jni.env[0].ExceptionCheck(jni.env) == JNI_TRUE
end

--- Resolve a class.
-- Tries FindClass() first; on a native thread that only sees the boot class
-- loader, so we fall back to the launcher activity's own class loader.
-- @tparam userdata jni the JNI context
-- @tparam string jni_name slash notation, e.g. "android/eink/EPDCDevice"
-- @tparam string dotted_name dot notation, e.g. "android.eink.EPDCDevice"
-- @return jclass or nil
function M.find_class(jni, jni_name, dotted_name)
    local clazz = jni.env[0].FindClass(jni.env, jni_name)
    if clazz ~= nil then
        return clazz
    end
    M.exception_clear(jni)

    if not dotted_name or android == nil or android.app.activity == nil then
        return nil
    end

    local activity = android.app.activity.clazz
    if activity == nil then
        return nil
    end

    local activity_class = jni.env[0].GetObjectClass(jni.env, activity)
    if activity_class == nil then
        M.exception_clear(jni)
        return nil
    end
    local get_class_loader = jni.env[0].GetMethodID(jni.env, activity_class,
        "getClassLoader", "()Ljava/lang/ClassLoader;")
    jni.env[0].DeleteLocalRef(jni.env, activity_class)
    if get_class_loader == nil then
        M.exception_clear(jni)
        return nil
    end

    local loader = jni.env[0].CallObjectMethod(jni.env, activity, get_class_loader)
    if loader == nil or M.exception_pending(jni) then
        M.exception_clear(jni)
        return nil
    end

    local loader_class = jni.env[0].GetObjectClass(jni.env, loader)
    local load_class = jni.env[0].GetMethodID(jni.env, loader_class,
        "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
    jni.env[0].DeleteLocalRef(jni.env, loader_class)
    if load_class == nil then
        M.exception_clear(jni)
        jni.env[0].DeleteLocalRef(jni.env, loader)
        return nil
    end

    local name = jni.env[0].NewStringUTF(jni.env, dotted_name)
    local resolved = jni.env[0].CallObjectMethod(jni.env, loader, load_class, name)
    jni.env[0].DeleteLocalRef(jni.env, name)
    jni.env[0].DeleteLocalRef(jni.env, loader)
    if resolved == nil or M.exception_pending(jni) then
        M.exception_clear(jni)
        return nil
    end
    return resolved
end

--- Look up a static method id, without leaving an exception behind.
function M.static_method(jni, clazz, name, signature)
    if clazz == nil then
        return nil
    end
    local mid = jni.env[0].GetStaticMethodID(jni.env, clazz, name, signature)
    if mid == nil then
        M.exception_clear(jni)
        return nil
    end
    return mid
end

--- Look up an instance method id of a class, without leaving an exception behind.
function M.method(jni, clazz, name, signature)
    if clazz == nil then
        return nil
    end
    local mid = jni.env[0].GetMethodID(jni.env, clazz, name, signature)
    if mid == nil then
        M.exception_clear(jni)
        return nil
    end
    return mid
end

--- Call a void static method. (This is what android.jni cannot do.)
-- Varargs are passed straight to JNI, so numbers must be wrapped in
-- ffi.new("int32_t", n) / ffi.new("int64_t", n) and strings must be jstrings.
function M.call_static_void(jni, clazz, mid, ...)
    if clazz == nil or mid == nil then
        return false
    end
    jni.env[0].CallStaticVoidMethod(jni.env, clazz, mid, ...)
    if M.exception_pending(jni) then
        M.exception_clear(jni)
        return false
    end
    return true
end

function M.call_static_int(jni, clazz, mid, ...)
    if clazz == nil or mid == nil then
        return nil
    end
    local res = jni.env[0].CallStaticIntMethod(jni.env, clazz, mid, ...)
    if M.exception_pending(jni) then
        M.exception_clear(jni)
        return nil
    end
    return tonumber(res)
end

function M.call_static_boolean(jni, clazz, mid, ...)
    if clazz == nil or mid == nil then
        return nil
    end
    local res = jni.env[0].CallStaticBooleanMethod(jni.env, clazz, mid, ...)
    if M.exception_pending(jni) then
        M.exception_clear(jni)
        return nil
    end
    return res == JNI_TRUE
end

function M.call_static_object(jni, clazz, mid, ...)
    if clazz == nil or mid == nil then
        return nil
    end
    local res = jni.env[0].CallStaticObjectMethod(jni.env, clazz, mid, ...)
    if M.exception_pending(jni) then
        M.exception_clear(jni)
        return nil
    end
    return res
end

function M.call_object(jni, obj, mid, ...)
    if obj == nil or mid == nil then
        return nil
    end
    local res = jni.env[0].CallObjectMethod(jni.env, obj, mid, ...)
    if M.exception_pending(jni) then
        M.exception_clear(jni)
        return nil
    end
    return res
end

--- Construct a Java object (NewObject with a <init> method id).
function M.new_object(jni, clazz, ctor_id, ...)
    if clazz == nil or ctor_id == nil then
        return nil
    end
    local obj = jni.env[0].NewObject(jni.env, clazz, ctor_id, ...)
    if M.exception_pending(jni) then
        M.exception_clear(jni)
        return nil
    end
    return obj
end

function M.call_int(jni, obj, mid, ...)
    if obj == nil or mid == nil then
        return nil
    end
    local res = jni.env[0].CallIntMethod(jni.env, obj, mid, ...)
    if M.exception_pending(jni) then
        M.exception_clear(jni)
        return nil
    end
    return tonumber(res)
end

--- Call a void *instance* method (the launcher's helper cannot, see the note
-- about static calls at the top of this file).
function M.call_void(jni, obj, mid, ...)
    if obj == nil or mid == nil then
        return false
    end
    jni.env[0].CallVoidMethod(jni.env, obj, mid, ...)
    if M.exception_pending(jni) then
        M.exception_clear(jni)
        return false
    end
    return true
end

function M.call_boolean(jni, obj, mid, ...)
    if obj == nil or mid == nil then
        return nil
    end
    local res = jni.env[0].CallBooleanMethod(jni.env, obj, mid, ...)
    if M.exception_pending(jni) then
        M.exception_clear(jni)
        return nil
    end
    return res == JNI_TRUE
end

--- Name of a java.lang.Class object, e.g. "java.lang.String" or "int".
function M.class_name(jni, class_obj)
    if class_obj == nil then
        return nil
    end
    local class_class = jni.env[0].GetObjectClass(jni.env, class_obj)
    local mid = M.method(jni, class_class, "getName", "()Ljava/lang/String;")
    jni.env[0].DeleteLocalRef(jni.env, class_class)
    if mid == nil then
        return nil
    end
    local str = M.call_object(jni, class_obj, mid)
    local name = M.to_string(jni, str)
    M.free(jni, str)
    return name
end

local PRIMITIVE_DESCRIPTORS = {
    void = "V", int = "I", long = "J", boolean = "Z",
    byte = "B", char = "C", short = "S", float = "F", double = "D",
}

--- JNI type descriptor of a java.lang.Class object ("I", "[B", "Ljava/lang/String;", ...).
function M.class_descriptor(jni, class_obj)
    local name = M.class_name(jni, class_obj)
    if name == nil then
        return nil
    end
    local primitive = PRIMITIVE_DESCRIPTORS[name]
    if primitive then
        return primitive
    end
    if name:sub(1, 1) == "[" then
        -- Already an array descriptor, only the dots need fixing.
        return (name:gsub("%.", "/"))
    end
    return "L" .. name:gsub("%.", "/") .. ";"
end

--- Enumerate every method *declared* by a class, with a ready-made JNI signature.
-- This is what makes the vendor bridge survive firmware updates: instead of
-- hardcoding "nativePostCommand" we look at what the class actually offers.
-- @treturn table|nil array of { name, static, params = {descriptor...}, ret, signature }
function M.describe_class_methods(jni, clazz)
    if clazz == nil then
        return nil
    end
    local class_class = jni.env[0].GetObjectClass(jni.env, clazz)
    local mid = M.method(jni, class_class, "getDeclaredMethods", "()[Ljava/lang/reflect/Method;")
    jni.env[0].DeleteLocalRef(jni.env, class_class)
    if mid == nil then
        return nil
    end
    local methods = M.call_object(jni, clazz, mid)
    if methods == nil then
        return nil
    end

    local out = {}
    local count = jni.env[0].GetArrayLength(jni.env, methods)
    for index = 0, count - 1 do
        local method = jni.env[0].GetObjectArrayElement(jni.env, methods, index)
        if method ~= nil then
            local method_class = jni.env[0].GetObjectClass(jni.env, method)
            local name_id = M.method(jni, method_class, "getName", "()Ljava/lang/String;")
            local modifiers_id = M.method(jni, method_class, "getModifiers", "()I")
            local params_id = M.method(jni, method_class, "getParameterTypes", "()[Ljava/lang/Class;")
            local return_id = M.method(jni, method_class, "getReturnType", "()Ljava/lang/Class;")
            jni.env[0].DeleteLocalRef(jni.env, method_class)

            local name
            if name_id then
                name = M.to_string(jni, M.call_object(jni, method, name_id))
            end

            local modifiers = 0
            if modifiers_id then
                modifiers = M.call_int(jni, method, modifiers_id) or 0
            end

            local params = {}
            if params_id then
                local types = M.call_object(jni, method, params_id)
                if types ~= nil then
                    local nparams = jni.env[0].GetArrayLength(jni.env, types)
                    for pindex = 0, nparams - 1 do
                        local param = jni.env[0].GetObjectArrayElement(jni.env, types, pindex)
                        if param ~= nil then
                            local descriptor = M.class_descriptor(jni, param)
                            if descriptor then
                                params[#params + 1] = descriptor
                            end
                            jni.env[0].DeleteLocalRef(jni.env, param)
                        end
                    end
                    jni.env[0].DeleteLocalRef(jni.env, types)
                end
            end

            local returns
            if return_id then
                local ret = M.call_object(jni, method, return_id)
                if ret ~= nil then
                    returns = M.class_descriptor(jni, ret)
                    jni.env[0].DeleteLocalRef(jni.env, ret)
                end
            end

            if name and returns then
                -- Modifier.STATIC == 0x8; (n / 8) % 2 is the bit test without
                -- depending on the bit library.
                local is_static = (math.floor(modifiers / 8) % 2) == 1
                out[#out + 1] = {
                    name = name,
                    static = is_static,
                    params = params,
                    ret = returns,
                    signature = "(" .. table.concat(params) .. ")" .. returns,
                }
            end
            jni.env[0].DeleteLocalRef(jni.env, method)
        end
    end
    jni.env[0].DeleteLocalRef(jni.env, methods)
    return out
end

--- The launcher exposes the MainActivity *instance* as `android.app.activity.clazz`.
function M.activity()
    if android == nil or android.app.activity == nil then
        return nil
    end
    return android.app.activity.clazz
end

--- Call an instance method on the launcher activity (e.g. getContentResolver).
function M.activity_method(jni, name, signature)
    local activity = M.activity()
    if activity == nil then
        return nil, nil
    end
    local activity_class = jni.env[0].GetObjectClass(jni.env, activity)
    local mid = M.method(jni, activity_class, name, signature)
    jni.env[0].DeleteLocalRef(jni.env, activity_class)
    return activity, mid
end

function M.new_string(jni, str)
    return jni.env[0].NewStringUTF(jni.env, str)
end

function M.free(jni, ref)
    if jni ~= nil and ref ~= nil then
        jni.env[0].DeleteLocalRef(jni.env, ref)
    end
end

function M.to_string(jni, javastring)
    if javastring == nil then
        return nil
    end
    -- COLON call: JNI:to_string is a method (it uses self.env).  Calling it with
    -- a dot passes the jstring as `self`, which fails with
    -- "'void *' has no member named 'env'" -- and that is exactly what broke the
    -- EPDC reflection.
    return jni:to_string(javastring)
end

function M.global_ref(jni, ref)
    if ref == nil then
        return nil
    end
    return jni.env[0].NewGlobalRef(jni.env, ref)
end

--- Describe every declared method of a class (diagnostics).
-- @return array of "name(args)" strings, or nil
function M.describe_methods(jni, clazz)
    if clazz == nil then
        return nil
    end
    local class_class = jni.env[0].GetObjectClass(jni.env, clazz)
    local mid = M.method(jni, class_class, "getDeclaredMethods", "()[Ljava/lang/reflect/Method;")
    jni.env[0].DeleteLocalRef(jni.env, class_class)
    if mid == nil then
        return nil
    end
    local methods = M.call_object(jni, clazz, mid)
    if methods == nil then
        return nil
    end

    local out = {}
    local count = jni.env[0].GetArrayLength(jni.env, methods)
    for i = 0, count - 1 do
        local method = jni.env[0].GetObjectArrayElement(jni.env, methods, i)
        if method ~= nil then
            local method_class = jni.env[0].GetObjectClass(jni.env, method)
            local to_string = M.method(jni, method_class, "toGenericString", "()Ljava/lang/String;")
            jni.env[0].DeleteLocalRef(jni.env, method_class)
            if to_string ~= nil then
                local str = M.call_object(jni, method, to_string)
                local lua_str = M.to_string(jni, str)
                if lua_str then
                    out[#out + 1] = lua_str
                end
                M.free(jni, str)
            end
            M.free(jni, method)
        end
    end
    jni.env[0].DeleteLocalRef(jni.env, methods)
    table.sort(out)
    return out
end

--- Run a shell command through the launcher's Runtime.exec bridge.
-- IMPORTANT: always invoke this as `sh -c "<command line>"`.
-- The launcher resolves argv[0] through PATH and then calls
-- `getInputStream()` on the returned Process *without* checking for a pending
-- Java exception.  If the program does not resolve (e.g. a `su` binary that
-- exists but is not executable), `Runtime.exec` throws IOException, the
-- Process object is NULL, and the next JNI call aborts the whole VM -- i.e. an
-- instant crash with no Lua traceback.  Going through `sh` avoids that
-- entirely: `sh` always exists, and a missing program is just a non-zero exit
-- status.
-- @treturn string stdout ("" on failure), or nil + error
function M.stdout(...)
    if android == nil or android.stdout == nil then
        return nil, "android.stdout unavailable"
    end
    local argv = { ... }
    local ok, out = pcall(android.stdout, unpack(argv))
    if not ok or out == nil then
        return nil, tostring(out)
    end
    return out
end

--- Run a shell command line, ignoring its output.
function M.execute(...)
    if android == nil or android.execute == nil then
        return nil, "android.execute unavailable"
    end
    local argv = { ... }
    local ok, res = pcall(android.execute, unpack(argv))
    if not ok then
        return nil, tostring(res)
    end
    return res
end

--- Run `cmd` through `sh -c` and return its stdout.
function M.sh(cmd)
    return M.stdout("sh", "-c", cmd)
end

--- Run `cmd` through `sh -c` and return its exit status.
function M.sh_status(cmd)
    return M.execute("sh", "-c", cmd)
end

--- Read a system property without spawning a bare binary.
function M.getprop(name)
    if android ~= nil and android.getprop ~= nil then
        local ok, value = pcall(android.getprop, name)
        if ok and value ~= nil and value ~= "" then
            return value
        end
    end
    local out = M.sh("getprop " .. name)
    if out then
        out = out:gsub("%s+$", "")
        if out ~= "" then
            return out
        end
    end
    return nil
end

M.JNI_TRUE = JNI_TRUE
M.ffi = ffi

return M
