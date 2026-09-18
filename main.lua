--[[--
iReader (掌阅) e-ink hardware adaptation for KOReader.

Two independent features, both reachable from
  设置(⚙) -> 手势 -> 翻页 -> 掌阅适配

  * 前光 / Frontlight      : drives the panel's LED backlight directly
                             (iReader has no public API for it, so this probes
                             several backends and lets you confirm one).
  * 水波纹翻页动画 / Ripple : arms the native SmartOS page-turn animation
                             through the vendor EPDC interface.

Safety model (learned the hard way)
-----------------------------------
Loading this plugin must never be able to kill KOReader at startup:

  * nothing here calls JNI, spawns a process, or probes hardware at load or
    init time; the risky work happens lazily, on the first page turn or on the
    first frontlight read/write (both user-initiated);
  * the JNI and hardware paths are armed with the crash canary (lib/canary.lua),
    so if one of them ever does take the process down, the next start detects
    the marker and disables just that feature instead of crash-looping;
  * `init()` is wrapped in pcall;
  * an emergency kill switch is available:
        - create an empty file <koreader settings>/ireader_disable_plugin, or
        - set `ireader_disabled = true` in the reader settings.
    Both make the plugin load as disabled, without having to delete it.

@module ireader
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")
local GetText = require("gettext")
local T = require("ffi/util").template
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local InputDialog = require("ui/widget/inputdialog")

-- Our own modules are loaded by path: a koplugin's own directory is not
-- guaranteed to be on package.path, and this keeps everything self-contained.
-- The `sibling` helper (repeated in each module) makes them shared singletons,
-- so a probe done by one module is visible to all of them.
local function sibling(name)
    local key = "ireader_lib_" .. name
    if package.loaded[key] == nil then
        local source = debug.getinfo(1, "S").source
        local path = source:sub(1, 1) == "@" and source:sub(2) or source
        local dir = path:match("^(.*[/\\])") or "./"
        package.loaded[key] = dofile(dir .. "lib/" .. name .. ".lua")
    end
    return package.loaded[key]
end

-- ---------------------------------------------------------------------------
-- breadcrumbs + emergency kill switch (both checked before anything else)
-- ---------------------------------------------------------------------------

-- Our own log: a native-level crash leaves no KOReader crash.log, so this is
-- the only way to know how far the plugin got.  See lib/trace.lua.
local trace = sibling("trace")
trace.rotate()
local previous_last = trace.last_step()
trace.step("=== launch ===")
if previous_last then
    trace.step("previous session ended at: " .. previous_last)
end

local disabled = false
do
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then
        local ok2, dir = pcall(function() return DataStorage:getSettingsDir() end)
        if ok2 and type(dir) == "string" then
            local f = io.open(dir .. "/ireader_disable_plugin", "r")
            if f then
                f:close()
                disabled = true
            end
        end
    end
    if G_reader_settings and G_reader_settings:isTrue("ireader_disabled") then
        disabled = true
    end
end

if disabled then
    trace.step("load: DISABLED by kill switch")
    logger.warn("[iReader] plugin disabled by user request (kill switch)")
    return { disabled = true }
end

local epdc = sibling("epdc")
local frontlight = sibling("frontlight")
local pageanim = sibling("pageanim")
local diag = sibling("diag")
trace.step("load: modules loaded")

-- ---------------------------------------------------------------------------
-- translations
-- ---------------------------------------------------------------------------

-- English is the gettext source language.  Our strings are not in KOReader's
-- l10n catalogues yet, so provide built-in Chinese labels for Chinese UIs and
-- prefer a real catalogue translation as soon as one exists.
local interface_lang = G_reader_settings:readSetting("language") or ""
local zh_ui = interface_lang:match("^zh") and true or false

local zh_fallback = {
    ["iReader adaptation"] = "掌阅适配",
    ["iReader page-turn ripple animation"] = "掌阅水波纹翻页动画",
    ["Enable"] = "启用",
    ["Other"] = "其他",
    ["Frontlight"] = "前光",
    ["Ripple page-turn animation"] = "水波纹翻页动画",
    ["Page-turn animation speed"] = "翻页动画速度",
    ["Slow"] = "慢",
    ["Standard"] = "标准",
    ["Fast"] = "快",
    ["Diagnostics"] = "诊断",
    ["Collect diagnostic report"] = "生成诊断报告",
    ["Frontlight backend"] = "前光驱动",
    ["Automatic"] = "自动",
    ["Detect frontlight backend…"] = "自动检测前光驱动…",
    ["Manual sysfs node…"] = "手动指定 sysfs 节点…",
    ["Manual Settings key…"] = "手动指定 Settings 键名…",
    ["Test ripple animation"] = "测试水波纹动效",
    ["Show current status"] = "查看当前状态",
    ["Restore defaults"] = "恢复默认设置",
    ["Show startup log"] = "查看启动日志",
    ["iReader startup log"] = "掌阅适配启动日志",
    ["Show the plugin's own breadcrumb log. If KOReader crashes without leaving a crash.log, the last line of this file says how far the plugin got."] =
        "查看插件自己的面包屑日志。如果 KOReader 闪退且没有 crash.log，这个文件的最后一行就是插件崩溃前走到的那一步。",
    ["Allow root (su) for the frontlight"] = "允许使用 root（su）控制前光",
    ["Re-enable EPDC probing"] = "重新启用 EPDC 探测",
    ["Re-enable frontlight takeover"] = "重新启用前光接管",
    ["Clear frontlight backend blacklist"] = "清除前光驱动黑名单",
    ["Frontlight backend blacklist cleared."] = "已清除前光驱动黑名单。",
    ["Grant system brightness permission (WRITE_SETTINGS)"] = "授予写入系统设置权限（WRITE_SETTINGS）",
    ["On this device the frontlight is driven by the system, so writing the framework brightness setting needs WRITE_SETTINGS.\n\nIf no dialog appears, grant it from a computer:\nadb shell appops set org.koreader.launcher WRITE_SETTINGS allow"] =
        "这台设备的前光由系统控制，所以要写系统的亮度设置就需要 WRITE_SETTINGS 权限。\n\n如果没弹出系统对话框，可以用电脑执行：\nadb shell appops set org.koreader.launcher WRITE_SETTINGS allow",
    ["A system dialog should have opened. Enable “Allow modifying system settings” for KOReader, then run the frontlight detection again."] =
        "应该弹出了系统对话框：请为 KOReader 打开“允许修改系统设置”，然后重新运行前光检测。",
    ["Could not open the permission dialog: %1"] = "无法打开权限对话框：%1",
    ["You can also grant it from a computer (fully revertible):\n\nadb shell appops set %1 WRITE_SETTINGS allow\n\nto undo:\n\nadb shell appops set %1 WRITE_SETTINGS default"] =
        "也可以用电脑授予（完全可还原）：\n\nadb shell appops set %1 WRITE_SETTINGS allow\n\n撤销：\n\nadb shell appops set %1 WRITE_SETTINGS default",
    ["Identify the system brightness key (read-only)"] = "识别系统亮度键（只读）",
    ["Reads a list of candidate Settings keys, asks you to move the system brightness slider, then shows which key changed. Nothing is written, no permission needed."] =
        "读取一组候选 Settings 键，然后请你去移动系统亮度滑块，再对比哪一个键发生了变化。只读、不需要任何权限。",
    ["Pull down the system panel, move the brightness slider, then tap Done.\n\n(Read-only: nothing is written.)"] =
        "请下拉系统面板、移动亮度滑块，然后点“完成”。\n\n（只读操作，不写入任何东西。）",
    ["Which Settings key moved:"] = "发生变化的 Settings 键：",
    ["Keys sampled: %1, changed: %2"] = "共采样 %1 项，发生变化 %2 项",
    ["... and %1 more"] = "……另有 %1 项",
    ["No candidate key changed. In that case the frontlight is driven by a vendor service rather than by the framework brightness setting."] =
        "没有任何候选键变化。这说明前光是由厂商服务驱动，而不是框架亮度设置。",
    ["System brightness key"] = "系统亮度键",
    ["Done"] = "完成",
    ["iReader adaptation failed in %1:\n%2"] = "掌阅适配在 %1 处出错：\n%2",
    ["A backend that crashed a previous session is skipped automatically. Use this to allow it again."] =
        "上一次运行中导致崩溃的驱动会被自动跳过；用这里可以重新允许它。",
    ["iReader e-ink hardware adaptation."] =
        "掌阅墨水屏硬件适配：前光控制与 SmartOS 原生水波纹翻页动画。",
    ["Frontlight: takes over brightness control and uses KOReader's own frontlight dialog (the Android one only changes the app window and cannot reach iReader's LED driver).\n\nThe backend is auto-detected; use Diagnostics if the light does not react."] =
        "前光：接管亮度控制，并使用 KOReader 自带的前光对话框（安卓自带对话框只改应用窗口亮度，控制不到掌阅的背光驱动）。\n\n驱动会在第一次调节时自动探测；如果灯光没有反应，请到“诊断”里确认。",
    ["Frontlight (needs root on this device)"] = "前光（本机型需要 root）",
    ["Measured on iReader Air3 Pro: the panel light is driven by a system service, the LED nodes are not writable by apps, no Settings key follows the system slider, and the vendor EPDC class has no light method. So this switch can only work with root (Diagnostics -> Allow root (su)). The page-turn ripple is unaffected by this."] =
        "在 iReader Air3 Pro 上实测：前光由系统服务驱动，LED 节点对普通应用不可写，没有任何 Settings 键跟随系统亮度滑块，厂商 EPDC 类里也没有 light 方法。因此这个开关只有在 root 后才有用（诊断 → 允许使用 root（su））。水波纹翻页动画不受影响。",
    ["Ripple page-turn animation: arms the native SmartOS water-ripple effect through the vendor EPDC interface, right before each page-turn frame is posted.\n\nThe animation speed is the one built into the firmware. The vendor interface is detected on the first page turn."] =
        "水波纹翻页动画：在每次翻页画面刷新前，通过厂商 EPDC 接口触发 SmartOS 原生水波纹动效。\n\n动画速度使用掌阅固件自带的效果；厂商接口会在第一次翻页时自动检测。",
    ["Speed of the native water-ripple page-turn animation. The ramp itself comes from the firmware; this only selects the speed flag."] =
        "掌阅原生水波纹翻页动画的速度。动画本身由固件实现，这里只选择速度档位。",
    ["Collect a read-only report about the frontlight/EPDC interfaces of this device, so the adapter can be pointed at the right node."] =
        "生成一份只读的设备探测报告（前光/EPDC 接口），用来确定正确的接口。",
    ["Choose which backend drives the frontlight. “Automatic” picks the first writable one."] =
        "选择前光驱动。“自动”会选择第一个可写的接口。",
    ["Walk through every frontlight backend and confirm the one that actually changes the light."] =
        "依次尝试所有前光驱动，并确认真正能改变亮度的那一个。",
    ["No frontlight backend was found on this device.\n\nRun “Collect diagnostic report” and share the result."] =
        "没有找到可用的前光驱动。\n\n请运行“生成诊断报告”并把结果发给我。",
    ["No backend changed the light.\n\nRun “Collect diagnostic report” and share the result."] =
        "没有任何驱动能改变前光。\n\n请运行“生成诊断报告”并把结果发给我。",
    ["Did the frontlight change just now (dim, then bright)?"] =
        "刚才前光有变化吗（先变暗、再变亮）？",
    ["Yes, use this"] = "有变化，用它",
    ["No, try next"] = "没变化，试下一个",
    ["Saved frontlight backend:\n%1"] = "已保存前光驱动：\n%1",
    ["Backend %1/%2:\n%3\n\nDid the frontlight change just now (dim, then bright)?"] =
        "正在测试驱动 %1/%2：\n%3\n\n刚才前光有变化吗（先变暗、再变亮）？",
    ["Backend %1/%2:\n%3\n\n%4\n\nDid the frontlight change just now (dim, then bright)?"] =
        "正在测试驱动 %1/%2：\n%3\n\n%4\n\n刚才前光有变化吗（先变暗、再变亮）？",
    ["The driver accepted the write."] = "驱动接受了写入。",
    ["The write was REFUSED: %1"] = "写入被拒绝：%1",
    ["No backend changed the light. A report was saved to %1 -- please share it."] =
        "没有任何驱动能改变前光。已自动生成报告并保存到 %1 —— 请把它发我。",
    ["iReader diagnostic report"] = "掌阅适配诊断报告",
    ["Saved to: %1"] = "已保存到：%1",
    ["Save"] = "保存",
    ["Cancel"] = "取消",
    ["Restore"] = "恢复",
    ["sysfs node"] = "sysfs 节点",
    ["Settings key"] = "Settings 键名",
    ["Full path of the LED node, e.g. /sys/class/backlight/lm3630a_leda"] =
        "LED 节点的完整路径，例如 /sys/class/backlight/lm3630a_leda",
    ["Settings.System key to use, e.g. screen_brightness"] =
        "要使用的 Settings.System 键名，例如 screen_brightness",
    ["Restore all iReader adaptation settings to their defaults?"] =
        "要把掌阅适配的所有设置恢复为默认值吗？",
    ["Restored."] = "已恢复默认设置。",
    ["Frontlight backend: %1"] = "前光驱动：%1",
    ["Page animation: %1"] = "翻页动画：%1",
    ["EPDC: %1"] = "EPDC：%1",
    ["Ripple test: effect code %1"] = "水波纹测试：效果码 %1",
    ["Ripple test failed: %1"] = "水波纹测试失败：%1",
    ["The detection wizard failed: %1"] = "检测向导出错：%1",
    ["These frontlight backends will be tried in order:\n\n%1\n\nEach one will first dim and then brighten the light."] =
        "将按顺序尝试以下前光驱动：\n\n%1\n\n每个驱动都会先把前光调暗、再调亮（注意屏幕变化）。",
    ["Start"] = "开始",
    ["android.eink.EPDCDevice declares:"] = "android.eink.EPDCDevice 实际声明的方法：",
    ["Some frontlight backends are blacklisted after a crash."] =
        "有前光驱动因上次崩溃被自动加入黑名单（可在诊断中清除）。",
    ["The vendor EPDC interface is unusable, so the native ripple animation is off.\n\nSee Diagnostics for the reason."] =
        "厂商 EPDC 接口不可用，原生水波纹动效已关闭。\n\n可在“诊断”中查看原因。",
    ["This feature was disabled automatically because a previous session crashed while using it.\n\nYou can re-enable it below, but if KOReader crashes again, leave it off and send me the diagnostic report."] =
        "该功能被自动禁用，因为上一次运行在使用它时崩溃了。\n\n可以在下面重新启用；如果再次闪退，请保持关闭并把诊断报告发我。",
    ["Re-probing EPDC on the next page turn."] = "将在下次翻页时重新探测 EPDC。",
    ["Frontlight takeover re-armed."] = "已重新启用前光接管。",
    ["Root mode toggled; the frontlight backend will be probed again."] =
        "已切换 root 模式，前光驱动会重新探测。",
    ["Disabled: the plugin does not touch EPDC any more."] =
        "已禁用：插件不再访问 EPDC。",
}

local function _(msgid)
    local translated = GetText(msgid)
    if translated ~= msgid then
        return translated
    end
    if zh_ui and zh_fallback[msgid] then
        return zh_fallback[msgid]
    end
    return msgid
end

-- ---------------------------------------------------------------------------
-- settings helpers
-- ---------------------------------------------------------------------------

local MENU_KEY = "ireader_adaptation"

local function frontlight_enabled()
    -- Dormant feature: the frontlight needs root on the tested device, so it is
    -- off unless explicitly enabled with `ireader_frontlight = true`.
    return G_reader_settings:isTrue("ireader_frontlight")
end

local function ripple_enabled()
    return G_reader_settings:nilOrTrue("ireader_ripple")
end

local function ripple_speed()
    local speed = G_reader_settings:readSetting("ireader_ripple_speed")
    if speed == "slow" or speed == "fast" then
        return speed
    end
    return "standard"
end

local function set_ripple_speed(speed)
    -- Save explicitly AND flush: KOReader only writes settings.reader.lua at its
    -- own flush points, which is why the speed appeared to reset on restart.
    G_reader_settings:saveSetting("ireader_ripple_speed", speed)
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

local function is_android()
    return Device.isAndroid and Device:isAndroid()
end

-- ---------------------------------------------------------------------------
-- feature wiring
-- ---------------------------------------------------------------------------

local IReader = WidgetContainer:extend{
    name = "ireader",
    is_doc_only = false,
}

--- Install or remove the frontlight hooks.  Touches no hardware.
function IReader:sync_frontlight()
    if not is_android() then
        return
    end
    if frontlight_enabled() then
        trace.step("init: frontlight -> install hooks")
        frontlight.install(Device)
    else
        trace.step("init: frontlight -> off")
        frontlight.uninstall()
    end
end

--- Install or remove the ripple hook.  Touches no hardware.
function IReader:sync_ripple()
    if not is_android() then
        return
    end
    if ripple_enabled() and not epdc.is_poisoned() then
        trace.step("init: ripple -> install hook")
        pageanim.install(Device, ripple_enabled, ripple_speed)
    else
        trace.step("init: ripple -> off" .. (epdc.is_poisoned() and " (poisoned)" or ""))
        pageanim.uninstall()
    end
end

function IReader:sync_all()
    self:sync_frontlight()
    self:sync_ripple()
end

-- The live instance, so menu callbacks (which have no back-reference to the
-- plugin) can re-apply the settings.
IReader.instance = nil

function IReader:init()
    IReader.instance = self

    if not is_android() then
        logger.info("[iReader] not an Android build, plugin disabled")
        return
    end

    -- Everything here is plain Lua: no JNI, no subprocesses, no hardware
    -- probing, so a broken device interface cannot take KOReader down at
    -- startup.  Still wrapped, because init() runs once per document.
    trace.step("init: start")
    local ok, err = pcall(function()
        if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
            self.ui.menu:registerToMainMenu(self)
        end
        trace.step("init: menu registered")
        diag.setup{
            epdc = epdc,
            frontlight = frontlight,
            pageanim = pageanim,
            trace = trace,
        }
        self:sync_all()
    end)
    if not ok then
        trace.step("init: FAILED " .. tostring(err))
        logger.warn("[iReader] init failed:", err)
    else
        trace.step("init: done")
    end
end

-- ---------------------------------------------------------------------------
-- menu helpers
-- ---------------------------------------------------------------------------

local function open_input_dialog(title, description, setting_key, on_saved)
    local dialog
    dialog = InputDialog:new{
        title = _(title),
        input = G_reader_settings:readSetting(setting_key) or "",
        description = _(description),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputValue()
                        if value and value ~= "" then
                            G_reader_settings:saveSetting(setting_key, value)
                        else
                            G_reader_settings:delSetting(setting_key)
                        end
                        UIManager:close(dialog)
                        if on_saved then
                            on_saved()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function show_status()
    local text = T(_("Frontlight backend: %1"), frontlight.driver_label()) .. "\n"
        .. T(_("Page animation: %1"), pageanim.is_installed() and "on" or "off") .. "\n"
        .. T(_("EPDC: %1"), epdc.status())
    if frontlight.has_blacklisted_drivers() then
        text = text .. "\n\n" .. _("Some frontlight backends are blacklisted after a crash.")
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 12,
    })
end

-- ---------------------------------------------------------------------------
-- callback guard
--
-- KOReader calls menu callbacks, dialog buttons and scheduled functions straight
-- from the main loop: a Lua error inside any of them is caught nowhere and ends
-- up on the crash screen.  Every callback of ours goes through these wrappers.
-- ---------------------------------------------------------------------------

local function report_callback_error(what, err)
    trace.step("error in " .. what .. ": " .. tostring(err))
    logger.warn("[iReader] error in", what, err)
    UIManager:show(InfoMessage:new{
        text = T(_("iReader adaptation failed in %1:\n%2"), what, tostring(err)),
        timeout = 12,
    })
end

--- Wrap a callback (no return value expected).
local function guard(what, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            report_callback_error(what, err)
        end
    end
end

--- Wrap a callback whose return value matters (menu `*_func` hooks).
local function guard_value(what, fn, fallback)
    return function(...)
        local ok, res = pcall(fn, ...)
        if not ok then
            report_callback_error(what, res)
            return fallback
        end
        return res
    end
end

--- Wrap every callback in a menu item table (recursively).
-- One pass over the built menu is more reliable than guarding callbacks one by
-- one as they are written.
local function guard_menu_items(items)
    if type(items) ~= "table" then
        return items
    end
    for _, item in ipairs(items) do
        if type(item) == "table" then
            local label = "menu item " .. tostring(item.text)
            if type(item.callback) == "function" then
                item.callback = guard(label, item.callback)
            end
            if type(item.sub_item_table_func) == "function" then
                item.sub_item_table_func = guard_value(label .. " (submenu)",
                    item.sub_item_table_func, {})
            end
            if type(item.checked_func) == "function" then
                item.checked_func = guard_value(label .. " (checked)",
                    item.checked_func, false)
            end
            if type(item.enabled_func) == "function" then
                item.enabled_func = guard_value(label .. " (enabled)",
                    item.enabled_func, false)
            end
            if type(item.sub_item_table) == "table" then
                guard_menu_items(item.sub_item_table)
            end
        end
    end
    return items
end

local function run_backend_wizard()
    -- Pre-flight without writing anything: enumerate what exists, tell the user
    -- what is about to be tried, and only then start poking the hardware.
    local drivers = {}
    local names = {}
    for _, entry in ipairs(frontlight.readonly_candidates()) do
        if entry.available and not entry.disabled then
            drivers[#drivers + 1] = entry.driver
            names[#names + 1] = entry.driver.label
        end
    end

    if #drivers == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No frontlight backend was found on this device.\n\nRun “Collect diagnostic report” and share the result."),
            timeout = 8,
        })
        return
    end

    local function try(index)
        local driver = drivers[index]
        if not driver then
            -- Everything has been tried: the diagnostic report is the next thing
            -- needed, so produce it right away instead of asking for it.
            local text = diag.collect()
            local path = diag.save(text)
            UIManager:show(TextViewer:new{
                title = _("iReader diagnostic report"),
                text = T(_("No backend changed the light. A report was saved to %1 -- please share it."),
                    tostring(path)) .. "\n\n" .. text,
            })
            return
        end

        -- safe_set() arms the per-backend crash canary and writes a breadcrumb,
        -- so a backend that kills the process is both attributed and skipped
        -- from the next start onwards.
        -- NOTE: never name this throwaway `_`: `_` is the gettext function in
        -- this file, and shadowing it breaks every later `_("...")` call in the
        -- same scope (that was the "attempt to call upvalue '_'" crash).
        local first_ok, first_err = frontlight.safe_set(driver, 15)
        UIManager:scheduleIn(0.8, guard("frontlight wizard (dim step)", function()
            local accepted, second_err = frontlight.safe_set(driver, 90)
            UIManager:scheduleIn(0.8, guard("frontlight wizard (dialog step)", function()
                -- "write refused" and "write accepted but no effect" look the same
                -- on an e-ink panel, so say which one it was.
                local result_text
                if accepted then
                    result_text = _("The driver accepted the write.")
                else
                    result_text = T(_("The write was REFUSED: %1"),
                        tostring(second_err or first_err or "?"))
                end
                UIManager:show(ConfirmBox:new{
                    text = T(_("Backend %1/%2:\n%3\n\n%4\n\nDid the frontlight change just now (dim, then bright)?"),
                        index, #drivers, driver.label, result_text),
                    ok_text = _("Yes, use this"),
                    cancel_text = _("No, try next"),
                    ok_callback = guard("frontlight wizard (save)", function()
                        G_reader_settings:saveSetting("ireader_frontlight_driver", driver.id)
                        frontlight.reset()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Saved frontlight backend:\n%1"), driver.label),
                            timeout = 4,
                        })
                    end),
                    cancel_callback = guard("frontlight wizard (next)", function()
                        UIManager:nextTick(guard("frontlight wizard (next step)", function()
                            try(index + 1)
                        end))
                    end),
                })
            end))
        end))
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("These frontlight backends will be tried in order:\n\n%1\n\nEach one will first dim and then brighten the light."),
            table.concat(names, "\n")),
        ok_text = _("Start"),
        cancel_text = _("Cancel"),
        ok_callback = guard("frontlight wizard (start)", function()
            try(1)
        end),
    })
end

local function collect_report()
    local text = diag.collect()
    local path = diag.save(text)
    UIManager:show(TextViewer:new{
        title = _("iReader diagnostic report"),
        text = path and (text .. "\n\n" .. T(_("Saved to: %1"), path)) or text,
    })
end

--- Read-only identification of the Settings key the system slider writes.
-- Two snapshots around a user action: whichever key changes IS the channel.
local function run_key_learning()
    local before = frontlight.sample_setting_keys()
    UIManager:show(ConfirmBox:new{
        text = _("Pull down the system panel, move the brightness slider, then tap Done.\n\n(Read-only: nothing is written.)"),
        ok_text = _("Done"),
        cancel_text = _("Cancel"),
        ok_callback = guard("key learning (compare)", function()
            local after = frontlight.sample_setting_keys()
            local after_map = {}
            for _, entry in ipairs(after) do
                after_map[entry.scope .. "." .. entry.key] = entry.value
            end

            local changed, lines = {}, {}
            for _, entry in ipairs(before) do
                local id = entry.scope .. "." .. entry.key
                local now = after_map[id]
                if now ~= entry.value then
                    changed[#changed + 1] = string.format("%s = %s -> %s", id,
                        tostring(entry.value), tostring(now))
                end
            end

            lines[#lines + 1] = T(_("Keys sampled: %1, changed: %2"), #before, #changed)
            lines[#lines + 1] = ""
            if #changed > 0 then
                for index = 1, math.min(#changed, 25) do
                    lines[#lines + 1] = changed[index]
                end
                if #changed > 25 then
                    lines[#lines + 1] = T(_("... and %1 more"), #changed - 25)
                end
            else
                lines[#lines + 1] = _("No candidate key changed. In that case the frontlight is driven by a vendor service rather than by the framework brightness setting.")
            end
            trace.step("frontlight: key learning sampled=" .. #before .. " changed=" .. #changed
                .. " first=" .. tostring(changed[1]))
            UIManager:show(TextViewer:new{
                title = _("System brightness key"),
                text = table.concat(lines, "\n"),
            })
        end),
    })
end

local function ripple_test(speed)
    local ok, effect = pageanim.test(speed)
    if ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Ripple test: effect code %1"), tostring(effect)),
            timeout = 4,
        })
        return
    end

    -- Failure is the interesting case: show what the vendor class really
    -- declares, in a viewer that can be scrolled and copied.
    local methods = epdc.describe_class()
    local text = T(_("Ripple test failed: %1"), tostring(effect))
    if type(methods) == "table" and #methods > 0 then
        text = text .. "\n\n" .. _("android.eink.EPDCDevice declares:") .. "\n"
            .. table.concat(methods, "\n")
        UIManager:show(TextViewer:new{
            title = _("iReader diagnostic report"),
            text = text,
        })
    else
        UIManager:show(InfoMessage:new{
            text = text,
            timeout = 12,
        })
    end
end

local build_menu_item

local function build_all_diagnostics_items()
    return {
        {
            text = _("Show current status"),
            keep_menu_open = true,
            callback = function()
                show_status()
            end,
        },
        {
            text = _("Show startup log"),
            help_text = _("Show the plugin's own breadcrumb log. If KOReader crashes without leaving a crash.log, the last line of this file says how far the plugin got."),
            keep_menu_open = true,
            callback = function()
                local text = trace.tail(40)
                UIManager:show(TextViewer:new{
                    title = _("iReader startup log"),
                    text = text .. "\n\n" .. T(_("Saved to: %1"), tostring(trace.path())),
                })
            end,
        },
        {
            text = _("Collect diagnostic report"),
            help_text = _("Collect a read-only report about the frontlight/EPDC interfaces of this device, so the adapter can be pointed at the right node."),
            keep_menu_open = true,
            callback = function()
                collect_report()
            end,
        },
        {
            text = _("Detect frontlight backend…"),
            help_text = _("Walk through every frontlight backend and confirm the one that actually changes the light."),
            keep_menu_open = true,
            callback = function()
                run_backend_wizard()
            end,
        },
        {
            text = _("Clear frontlight backend blacklist"),
            enabled_func = function()
                return frontlight.has_blacklisted_drivers()
            end,
            help_text = _("A backend that crashed a previous session is skipped automatically. Use this to allow it again."),
            keep_menu_open = true,
            callback = function()
                frontlight.clear_driver_blacklist()
                frontlight.reset()
                UIManager:show(InfoMessage:new{
                    text = _("Frontlight backend blacklist cleared."),
                    timeout = 4,
                })
            end,
        },
        {
            text = _("Frontlight backend"),
            help_text = _("Choose which backend drives the frontlight. “Automatic” picks the first writable one."),
            sub_item_table_func = function()
                local items = {}
                local function configured()
                    return G_reader_settings:readSetting("ireader_frontlight_driver") or "auto"
                end
                items[#items + 1] = {
                    text = _("Automatic"),
                    radio = true,
                    checked_func = function()
                        return configured() == "auto"
                    end,
                    callback = function(touchmenu_instance)
                        G_reader_settings:delSetting("ireader_frontlight_driver")
                        frontlight.reset()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                }
                -- Read-only listing: opening a menu must not poke the hardware.
                for _, entry in ipairs(frontlight.readonly_candidates()) do
                    local driver = entry.driver
                    local label = driver.label
                    if entry.disabled then
                        label = label .. " (disabled)"
                    elseif not entry.available then
                        label = label .. " (?)"
                    end
                    items[#items + 1] = {
                        text = label,
                        radio = true,
                        checked_func = function()
                            return configured() == driver.id
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("ireader_frontlight_driver", driver.id)
                            frontlight.reset()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        help_text = tostring(entry.note or ""),
                    }
                end
                return items
            end,
        },
        {
            text = _("Manual sysfs node…"),
            keep_menu_open = true,
            callback = function()
                open_input_dialog("sysfs node",
                    "Full path of the LED node, e.g. /sys/class/backlight/lm3630a_leda",
                    "ireader_sysfs_path", function()
                        frontlight.reset()
                    end)
            end,
        },
        {
            text = _("Manual Settings key…"),
            keep_menu_open = true,
            callback = guard("manual settings key", function()
                open_input_dialog("Settings key",
                    "Settings.System key to use, e.g. screen_brightness",
                    "ireader_settings_key", function()
                        frontlight.reset()
                    end)
            end),
        },
        {
            text = _("Grant system brightness permission (WRITE_SETTINGS)"),            help_text = _("On this device the frontlight is driven by the system, so writing the framework brightness setting needs WRITE_SETTINGS.\n\nIf no dialog appears, grant it from a computer:\nadb shell appops set org.koreader.launcher WRITE_SETTINGS allow"),
            keep_menu_open = true,
            callback = guard("write settings request", function()
                local ok, err = frontlight.request_write_settings()
                local package = frontlight.package_name() or "org.koreader.launcher"
                local text
                if ok then
                    text = _("A system dialog should have opened. Enable “Allow modifying system settings” for KOReader, then run the frontlight detection again.")
                else
                    text = T(_("Could not open the permission dialog: %1"), tostring(err))
                        .. "\n\n" .. T(_("You can also grant it from a computer (fully revertible):\n\nadb shell appops set %1 WRITE_SETTINGS allow\n\nto undo:\n\nadb shell appops set %1 WRITE_SETTINGS default"), package)
                end
                UIManager:show(InfoMessage:new{
                    text = text,
                    timeout = 20,
                })
            end),
        },
        {
            text = _("Identify the system brightness key (read-only)"),
            help_text = _("Reads a list of candidate Settings keys, asks you to move the system brightness slider, then shows which key changed. Nothing is written, no permission needed."),
            keep_menu_open = true,
            callback = guard("key learning", function()
                run_key_learning()
            end),
        },
        {
            text = _("Allow root (su) for the frontlight"),
            checked_func = function()
                return G_reader_settings:isTrue("ireader_allow_root")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                G_reader_settings:flipNilOrFalse("ireader_allow_root")
                frontlight.reset()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text = _("Test ripple animation"),
            sub_item_table = {
                {
                    text = _("Slow"),
                    callback = function()
                        ripple_test("slow")
                    end,
                },
                {
                    text = _("Standard"),
                    callback = function()
                        ripple_test("standard")
                    end,
                },
                {
                    text = _("Fast"),
                    callback = function()
                        ripple_test("fast")
                    end,
                },
            },
        },
        {
            text = _("Re-enable EPDC probing"),
            enabled_func = function()
                return epdc.is_poisoned()
            end,
            help_text = _("This feature was disabled automatically because a previous session crashed while using it.\n\nYou can re-enable it below, but if KOReader crashes again, leave it off and send me the diagnostic report."),
            keep_menu_open = true,
            callback = function()
                epdc.reset()
                local plugin = IReader.instance
                if plugin then
                    plugin:sync_ripple()
                end
                UIManager:show(InfoMessage:new{
                    text = _("Re-probing EPDC on the next page turn."),
                    timeout = 4,
                })
            end,
        },
        {
            text = _("Re-enable frontlight takeover"),
            enabled_func = function()
                return frontlight.is_poisoned()
            end,
            help_text = _("This feature was disabled automatically because a previous session crashed while using it.\n\nYou can re-enable it below, but if KOReader crashes again, leave it off and send me the diagnostic report."),
            keep_menu_open = true,
            callback = function()
                frontlight.reset()
                local plugin = IReader.instance
                if plugin then
                    plugin:sync_frontlight()
                end
                UIManager:show(InfoMessage:new{
                    text = _("Frontlight takeover re-armed."),
                    timeout = 4,
                })
            end,
        },
        {
            text = _("Restore defaults"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Restore all iReader adaptation settings to their defaults?"),
                    ok_text = _("Restore"),
                    ok_callback = function()
                        for _, key in ipairs({
                            "ireader_frontlight",
                            "ireader_ripple",
                            "ireader_ripple_speed",
                            "ireader_frontlight_driver",
                            "ireader_sysfs_path",
                            "ireader_settings_key",
                            "ireader_allow_root",
                        }) do
                            G_reader_settings:delSetting(key)
                        end
                        epdc.reset()
                        frontlight.reset()
                        local plugin = IReader.instance
                        if plugin then
                            plugin:sync_all()
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("Restored."),
                            timeout = 3,
                        })
                    end,
                })
            end,
        },
    }
end

-- ---------------------------------------------------------------------------
-- published menu
--
-- The finished menu deliberately shows only the entries below.  Everything the
-- investigation needed but a normal user does not (root toggle, WRITE_SETTINGS
-- request, canary resets, key learning, breadcrumb viewer) is still implemented
-- and documented in the README -- as settings keys and marker files -- it is
-- simply not part of the user facing menu any more.
-- ---------------------------------------------------------------------------

local DIAG_VISIBLE = {
    ["Show current status"] = true,
    ["Collect diagnostic report"] = true,
    ["Detect frontlight backend…"] = true,
    ["Frontlight backend"] = true,
    ["Manual sysfs node…"] = true,
    ["Manual Settings key…"] = true,
    ["Test ripple animation"] = true,
    ["Restore defaults"] = true,
}

local function build_diagnostics_items()
    local out = {}

    -- 前光: kept first inside "Other", as a clearly labelled experimental path.
    out[#out + 1] = {
        text = _("Frontlight"),
        checked_func = function()
            return frontlight_enabled()
        end,
        help_text = _("Frontlight: takes over brightness control and uses KOReader's own frontlight dialog (the Android one only changes the app window and cannot reach iReader's LED driver).\n\nThe backend is auto-detected; use Diagnostics if the light does not react.")
            .. "\n\n"
            .. _("Measured on iReader Air3 Pro: the panel light is driven by a system service, the LED nodes are not writable by apps, no Settings key follows the system slider, and the vendor EPDC class has no light method. So this switch can only work with root (Diagnostics -> Allow root (su)). The page-turn ripple is unaffected by this."),
        callback = guard("frontlight toggle", function(touchmenu_instance)
            G_reader_settings:flipNilOrFalse("ireader_frontlight")
            local plugin = IReader.instance
            if plugin then
                plugin:sync_frontlight()
            end
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end),
    }

    for _, item in ipairs(build_all_diagnostics_items()) do
        if type(item) == "table" and DIAG_VISIBLE[item.text] then
            out[#out + 1] = item
        end
    end
    return out
end

build_menu_item = function()
    local item = guard_menu_items({
        text = _("iReader page-turn ripple animation"),
        help_text = _("iReader e-ink hardware adaptation."),
        sub_item_table = {
            {
                text = _("Enable"),
                checked_func = function()
                    return ripple_enabled()
                end,
                help_text = _("Ripple page-turn animation: arms the native SmartOS water-ripple effect through the vendor EPDC interface, right before each page-turn frame is posted.\n\nThe animation speed is the one built into the firmware. The vendor interface is detected on the first page turn."),
                callback = function(touchmenu_instance)
                    -- Real toggle: save the new value, flush it to disk, re-arm.
                    local enable = not ripple_enabled()
                    G_reader_settings:saveSetting("ireader_ripple", enable)
                    if G_reader_settings.flush then
                        G_reader_settings:flush()
                    end
                    if enable and epdc.is_poisoned() then
                        -- Turning it on also clears a crash-disable left over
                        -- from an older session.
                        epdc.reset()
                    end
                    local plugin = IReader.instance
                    if plugin then
                        plugin:sync_ripple()
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Page-turn animation speed"),
                help_text = _("Speed of the native water-ripple page-turn animation. The ramp itself comes from the firmware; this only selects the speed flag. The choice is saved immediately."),
                sub_item_table = {
                    {
                        text = _("Slow"),
                        radio = true,
                        checked_func = function()
                            return ripple_speed() == "slow"
                        end,
                        callback = function(touchmenu_instance)
                            set_ripple_speed("slow")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    },
                    {
                        text = _("Standard"),
                        radio = true,
                        checked_func = function()
                            return ripple_speed() == "standard"
                        end,
                        callback = function(touchmenu_instance)
                            set_ripple_speed("standard")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    },
                    {
                        text = _("Fast"),
                        radio = true,
                        checked_func = function()
                            return ripple_speed() == "fast"
                        end,
                        callback = function(touchmenu_instance)
                            set_ripple_speed("fast")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    },
                },
            },
        },
    })
    return item
end

function IReader:addToMainMenu(menu_items)
    -- Called by ReaderMenu (and FileManagerMenu) on every menu build, and by
    -- KOReader's debug guard with a throw-away table: stay defensive.
    if type(menu_items) ~= "table" then
        return
    end

    local ok, err = pcall(function()
        local item = build_menu_item()

        -- 设置 -> 手势 -> 翻页 -> 掌阅适配
        local page_turns = menu_items.page_turns
        if type(page_turns) == "table" and type(page_turns.sub_item_table) == "table" then
            table.insert(page_turns.sub_item_table, item)
            return
        end

        -- FileManager has no 翻页 submenu: add our own entry to 手势 instead.
        item.sorting_hint = "taps_and_gestures"
        menu_items[MENU_KEY] = item
    end)
    if not ok then
        trace.step("error in addToMainMenu: " .. tostring(err))
        logger.warn("[iReader] addToMainMenu failed:", err)
    end
end

return IReader
