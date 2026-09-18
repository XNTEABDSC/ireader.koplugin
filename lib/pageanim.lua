--[[--
Water-ripple page-turn animation for 掌阅 (iReader) SmartOS devices.

How it works
------------
`android.eink.EPDCDevice.nativePostCommand("next-effect-type <code>")` arms the
controller's water-ripple animation for the *next* frame posted to the panel, so
the only thing we have to get right is the timing: the command must be issued
immediately before the post that shows the new page.

KOReader's Android framebuffer posts frames in
`ffi/framebuffer_android.lua` -> `framebuffer:_updateWindow()`, which does
`ANativeWindow_lock` / blit / `ANativeWindow_unlockAndPost`.  Every refresh mode
(full, partial, ui, fast, flash...) goes through it.

So we wrap the framebuffer instance's `_updateWindow` and, when the reader has
just moved to another page, arm the ripple right before the original method
runs.  The "did the page change?" test is done at post time instead of hooking
page-turn gestures, which makes it independent of *how* the page was turned
(swipe, tap, key, TOC jump, auto-turn, skim...).

Cost control: the vendor interface is only probed when a page turn actually
happens (never at startup), and the probe is armed with the crash canary.

This is a no-op on devices where EPDC is unavailable.

@module ireader.pageanim
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

local epdc = sibling("epdc")
local trace = sibling("trace")

local M = {}

local state = {
    installed = false,
    screen = nil,
    original_update_window = nil,
    last_document = nil,
    last_page = nil,
    last_direction = nil,
    fired = 0,
}

--- The open document (ReaderUI instance) and its current page.
-- Deliberately reads `package.loaded` instead of calling require(): this runs
-- on every framebuffer post, including posts that can happen while readerui.lua
-- is still being loaded (plugin init runs inside ReaderUI:init), and Lua 5.1's
-- require() has no cyclic-load guard -- a second load of readerui.lua from here
-- could recurse.
local function current_document()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if not ReaderUI then
        return nil, nil, nil
    end
    local instance = ReaderUI.instance
    if not instance then
        return nil, nil, nil
    end
    local paging = instance.paging
    if paging and type(paging.current_page) == "number" then
        return instance, paging.current_page, "paging"
    end
    local rolling = instance.rolling
    if rolling and type(rolling.current_page) == "number" then
        return instance, rolling.current_page, "rolling"
    end
    return instance, nil, nil
end

--- Is a page-turn ripple wanted right now?
local function ripple_pending()
    local document, page, mode = current_document()
    if document == nil then
        -- No document (file manager, menus, ...): forget the old page so that
        -- opening a new document does not look like a page turn.
        state.last_document = nil
        state.last_page = nil
        return false
    end

    if document ~= state.last_document then
        -- First frame of a (new) document: just take a baseline.
        state.last_document = document
        state.last_page = page
        return false
    end

    if page == nil then
        return false
    end

    local previous = state.last_page
    state.last_page = page

    if previous == nil or previous == page then
        return false
    end

    if mode == "rolling" then
        -- Rolling mode reports a fractional position while scrolling; only
        -- react when the integer page actually changed.
        if math.floor(previous) == math.floor(page) then
            return false
        end
    end

    state.last_direction = page > previous and "forward" or "backward"
    return true
end

--- Hook the Android framebuffer post path.
-- Does no probing and no JNI: it only installs the wrapper.
-- @tparam table Device the KOReader device singleton
-- @tparam function is_enabled returns whether the ripple is currently enabled
-- @tparam function get_speed returns "slow" | "standard" | "fast"
function M.install(Device, is_enabled, get_speed)
    if state.installed or not Device or not Device.screen then
        return false
    end
    local screen = Device.screen
    if type(screen._updateWindow) ~= "function" then
        logger.dbg("[iReader] page animation: no framebuffer _updateWindow(), skipping")
        return false
    end

    state.screen = screen
    state.original_update_window = screen._updateWindow
    state.is_enabled = is_enabled
    state.get_speed = get_speed
    state.installed = true

    -- Keep the original in a local upvalue: M.uninstall() may run from inside
    -- this very wrapper (when the vendor interface turns out to be unusable),
    -- and the call below must still reach the real implementation.
    local original = state.original_update_window
    screen._updateWindow = function(self, ...)
        if M:should_arm() then
            M:arm()
        end
        return original(self, ...)
    end

    logger.info("[iReader] page-turn ripple hook installed")
    trace.step("pageanim: hook installed")
    return true
end

--- Remove the hook (used when the user disables the feature).
function M.uninstall()
    if not state.installed then
        return false
    end
    local screen = state.screen
    if screen and state.original_update_window then
        screen._updateWindow = state.original_update_window
    end
    state.installed = false
    state.screen = nil
    state.original_update_window = nil
    state.last_document = nil
    state.last_page = nil
    logger.info("[iReader] page-turn ripple hook removed")
    return true
end

function M.is_installed()
    return state.installed
end

function M:should_arm()
    if state.is_enabled and not state.is_enabled() then
        return false
    end
    return ripple_pending()
end

function M:arm()
    -- Probe the vendor interface now: this is the first moment where it matters,
    -- and it is user-initiated (a page turn), never part of startup.
    if not epdc.ensure_probed() then
        -- EPDC is definitively not usable here: unhook so that we stop paying
        -- a per-frame cost for nothing.
        trace.step("ripple: unusable -> unhooked (" .. tostring(epdc.status()) .. ")")
        logger.info("[iReader] ripple hook removed:", epdc.status())
        M.uninstall()
        return false
    end
    local speed = state.get_speed and state.get_speed() or "standard"
    local ok, effect = epdc.apply_page_turn(state.last_direction ~= "backward", speed)
    if ok then
        if state.fired == 0 then
            -- Only the first one is worth a breadcrumb (this runs per page turn).
            trace.step("ripple: first arm ok, effect=" .. tostring(effect))
        end
        state.fired = state.fired + 1
        logger.dbg("[iReader] ripple armed, effect =", effect)
    end
    return ok
end

--- Fire a ripple immediately and repaint, so the user can preview the effect.
function M.test(speed)
    if not epdc.ensure_probed() then
        return false, epdc.status()
    end
    local ok, effect = epdc.apply_page_turn(true, speed)
    if not ok then
        return false, "command rejected"
    end
    local UIManager = require("ui/uimanager")
    UIManager:setDirty(nil, "full")
    return true, effect
end

function M.status()
    if not state.installed then
        return "page animation: hook not installed"
    end
    return string.format("page animation: hooked (%d ripples fired this session)", state.fired)
end

return M
