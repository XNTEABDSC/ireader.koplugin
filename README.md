# ireader.koplugin

KOReader 的**掌阅（iReader）墨水屏适配插件** —— 使用掌阅固件原生的**水波纹翻页动画**。

| 项目 | 说明 |
| --- | --- |
| 适用设备 | 掌阅 iReader 墨水屏（SmartOS 4.x，Android） |
| 实测机型 | **iReader Air3 Pro / SmartOS 4.0.1.212.0** |
| KOReader | Android 版，2025.x / 2026.x 实测通过 |
| 当前状态 | **水波纹翻页动画：可用（已实测）** · **前光：已终止实现（需要 root）** |
| 许可证 | GPLv3（与 KOReader 相同） |

---

## 功能

### 1. 水波纹翻页动画（可用，已实测）

调用掌阅私有 EPDC 接口，让**固件自己**完成翻页水波纹动效；插件只负责在正确的时机、用正确的参数触发它。

- 动画曲线与时长全部来自固件，**不是软件模拟**；
- 方向随屏幕旋转、前进/后退自动选择；速度三档（慢 / 标准 / 快）；
- 触发点绑定在**画面送显那一帧之前**，所以滑动、点击、按键、目录跳转、自动翻页都生效。

实测结果（Air3 Pro / SmartOS 4.0.1）：效果码 `65`，翻页水波纹正常。

### 2. 前光（已终止实现，且不再出现在菜单中）

> **状态：因需要 root 而终止实现。代码保留在 `lib/frontlight.lua` 中，默认关闭，菜单里已移除。**
> 本节仅作为记录：说明为什么没有这个功能，以及将来若在 root 设备上继续的入手点。

这不是"接口还没找到"，而是**权限门 + 厂商实现方式**。以下每条均为该机型上的**实测**结果：

| 通道 | 实测结果 |
| --- | --- |
| `/sys/class/backlight/lm3630a_leda` / `lm3630a_ledb` | 节点**存在**（就是前光），写入 → **`Permission denied`** |
| 系统亮度设置（`screen_brightness` 等候选键） | 拖动系统下拉栏亮度滑块，**没有任何键发生变化** |
| 厂商类 `android.eink.EPDCDevice` | 反射列出全部方法，**没有** light/brightness 方法 |
| `Activity.window.screenBrightness`（免权限） | 写入被接受，但**灯不动** |
| `settings list`（枚举全部设置键） | 应用 uid **被拒绝**（`settings` 是 shell 专用 wrapper） |

结论：该机型的阅读灯由**系统服务（SystemUI 内部的厂商实现）直接驱动内核节点**，第三方应用既没有节点写权限，
也没有可及的 Settings 键或厂商 API。`WRITE_SETTINGS` 同样无效（已用只读实验证伪）。

#### 保留的测试路径（**未经实际测试**）

设备 root 后可以尝试下面这条路径。代码已实现，但**作者没有在 root 设备上验证过**：

1. 在 KOReader 的 `settings/settings.reader.lua` 中加入一行后重启：

   ```lua
   ["ireader_allow_root"] = true,
   ```

   此后 sysfs 后端在直接写入失败时会回退到
   `su -c 'echo N > /sys/class/backlight/lm3630a_leda/brightness'`
   （用 `sh -c` 包装，避免直接执行 `su` 触发启动器的安全问题）。
2. 菜单 **其他 → 自动检测前光驱动…**，确认出现「sysfs: LM3630A (iReader)」并观察灯是否变化；
3. 或 **其他 → 手动指定 sysfs 节点…** 直接填节点路径测试。

> 未 root 的设备上这条路径必然无效；作者不提供 root 操作指导。

---

## 安装

1. 解压 `ireader.koplugin.zip`；
2. 把 `ireader.koplugin` 文件夹放进 KOReader 插件目录：

   ```
   /sdcard/koreader/plugins/ireader.koplugin/
   ```

3. 重启 KOReader；
4. 打开任意书籍 → 顶部菜单 → **设置（⚙）→ 手势 → 翻页 → 掌阅水波纹翻页动画**。

> 这是 **koplugin**（不是 `patches/` 补丁），Google Play 版与 F-Droid 版都可用。

## 菜单

```
设置（⚙）
└── 手势
    └── 翻页
        └── 掌阅水波纹翻页动画
            ├── ☑ 启用              ← 点击即可开/关（立即生效并保存）
            └── 翻页动画速度
                  ├── ○ 慢
                  ├── ○ 标准
                  └── ○ 快
```

- 「启用」是真正的开关：点击后立即挂上/摘掉翻页钩子，并写入 `settings.reader.lua`；
- 速度选择**立即写入并落盘**（插件会显式 `flush()`，不依赖 KOReader 自己的写入时机），重启后保持；
- 前光与调试项**已从菜单移除**（见下文"前光：已终止"）：前光相关代码仍保留在 `lib/frontlight.lua` 中，
  但默认关闭、不再出现在菜单里；需要排查问题时可以查看 `ireader_trace.log`。

在文件管理器里没有「翻页」子菜单，此时该插件会作为「手势」菜单的一项出现。

## 工作原理

### EPDC 命令

```java
Class.forName("android.eink.EPDCDevice")
    .getMethod("nativePostCommand", String.class)
    .invoke(null, "next-effect-type " + effect);
Class.forName("android.eink.EPDCDevice")
    .getMethod("setForceNextPostMode", int.class)
    .invoke(null, 0x01000063);
```

`next-effect-type` 为**下一次**送显的画面挂上水波纹，`setForceNextPostMode` 让下一次送显按翻页处理。
`effect = 方向码 | 速度位`：

| 显示旋转 | 前进 | 后退 |
| --- | --- | --- |
| 0 竖屏 | 1 | 2 |
| 1 横屏 | 4 | 3 |
| 2 反向竖屏 | 2 | 1 |
| 3 反向横屏 | 3 | 4 |

| 速度 | 速度位 |
| --- | --- |
| 慢 | 128 |
| 标准 | 64 |
| 快 | 0 |

### 为什么需要"方法发现"

不同固件的方法名/签名并不一致：本机实测为 **`nativePostCommand(String)` 且返回 `int`**，而社区参考实现里是返回 `void`。
因此插件先按已知签名查找，找不到就用 **Java 反射枚举该类的全部方法**，按"形状"匹配
（名字含 `postcommand`/`post` 且只有一个 `String` 参数），并按**真实返回类型**选择 JNI 调用方式
（用 `CallStaticVoidMethod` 调用非 void 方法属未定义行为，会崩）。

### 触发时机

Android 版 KOReader 的所有刷新最终都经过 `ffi/framebuffer_android.lua` 的
`framebuffer:_updateWindow()`（`ANativeWindow_lock` → blit → `ANativeWindow_unlockAndPost`）。
插件把设备上的 `_updateWindow` 包了一层：**在真正送显之前**，若当前页号与上次送显不同，就先发 EPDC 命令。
这样不依赖任何翻页入口，且命令必然紧贴那一帧。

---

## 诊断与排错

- **诊断报告**：菜单「生成诊断报告」，同时写入
  `koreader/settings/ireader_probe.log`（含机型属性、全部灯节点及权限、候选设置键、EPDC 方法列表、包名、面包屑日志）。
- **面包屑日志**：`koreader/settings/ireader_trace.log`。原生层崩溃不会留下 KOReader 的 `crash.log`，
  这份日志每行一个步骤并立即落盘，**最后一行就是崩溃点**。
- **崩溃金丝雀**：插件在有风险的调用前后写/删标记文件
  `koreader/settings/ireader_<name>.pending`。若某次调用导致进程崩溃，标记会留下，
  下次启动**只禁用该功能**而不是反复闪退；标记带插件版本号，**升级后自动作废**。
  手动恢复：删除对应 `.pending` 文件（如 `ireader_epdc.pending`、`ireader_frontlight_sysfs_lm3630a.pending`）。
- **紧急停用**：在 `koreader/settings/` 下新建空文件 `ireader_disable_plugin`，插件会以禁用状态加载（删掉即恢复），无需卸载。

## 文件结构

```
ireader.koplugin/
├── _meta.lua            插件元信息
├── main.lua             菜单、设置项、功能装配
├── lib/
│   ├── jni.lua          JNI 封装（异常文本捕获 + 上游缺陷绕过）
│   ├── canary.lua       崩溃金丝雀（带版本号，升级自动作废）
│   ├── trace.lua        面包屑日志
│   ├── epdc.lua         EPDC 桥 + 方法发现 + 水波纹命令编码
│   ├── pageanim.lua     在送显前触发水波纹
│   ├── frontlight.lua   前光后端探测 / PowerD 接管（前光功能已终止）
│   └── diag.lua         只读诊断报告
└── README.md
```

## 已知限制

- 仅适用于**掌阅 SmartOS 4.x**（依赖其私有 `android.eink.EPDCDevice`）；
- 其它设备上「启用」会被自动关闭，不影响 KOReader 运行；
- **前光功能已终止**（需要 root），菜单中的前光相关项仅为未实测的测试路径；
- 色温（暖光）未实现；
- 速度档位对应固件自带的三种速度位，具体观感由固件决定。

## 参考

- [legadoM-Ink · IReaderPageH.kt](https://github.com/GymMickey/legadoM-Ink/blob/main/app/src/main/java/io/legado/app/lib/eink/IReaderPageH.kt) —— EPDC 方向表与速度位的最初来源
- [Shihon · SmartOsPageTurnEffect.kt](https://github.com/conezcc/Shihon/blob/main/app/src/main/java/eu/kanade/tachiyomi/util/system/SmartOsPageTurnEffect.kt) —— 方向/速度编码与设备判定
- [android-luajit-launcher issue #598](https://github.com/koreader/android-luajit-launcher/issues/598) —— iReader 前光 sysfs 节点的来源
- [koreader/koreader](https://github.com/koreader/koreader) 与 [koreader/android-luajit-launcher](https://github.com/koreader/android-luajit-launcher) —— 设备 / 前光 / JNI 接口

## 许可证

GPLv3，与 KOReader 相同。

---

## English

A KOReader plugin that enables the **native SmartOS water-ripple page-turn
animation** on 掌阅 (iReader) e-ink devices.

* **Ripple animation — working, verified** on iReader Air3 Pro / SmartOS 4.0.1.
  It drives the vendor `android.eink.EPDCDevice` command channel
  (`next-effect-type <direction|speed>` plus `setForceNextPostMode(0x01000063)`)
  right before each page-turn frame is posted, so swipes, taps, keys, TOC jumps
  and auto-turn all work.  The animation itself is the one built into the
  firmware.  The vendor method is located **by reflection** (name shape plus
  parameter types) and invoked according to its real return type, because
  firmware variants differ (this device returns `int`, not `void`).
* **Frontlight — discontinued: it requires root.** On the tested device the
  panel light is driven by a system service: the LED sysfs nodes exist but are
  not writable by apps (`Permission denied`), no Settings key follows the system
  brightness slider, the vendor EPDC class has no light method, and
  `WRITE_SETTINGS` does not help either.  An untested root-only test path is
  kept in the code and documented above.
* Menu: **Settings ⚙ → Taps and gestures → Page turns → iReader page-turn ripple animation**.
* Diagnostics: *Collect diagnostic report* (written to `koreader/settings/ireader_probe.log`)
  plus a breadcrumb log at `koreader/settings/ireader_trace.log`, because a
  native crash leaves no KOReader `crash.log`.
* License: GPLv3.

## 更新日志

- **0.6.0** —— 无用的菜单选项的整理；修复koreader重启时选择的翻页动画的速度回到标准的bug；修复启用选项无法切换的bug；
- **0.5.0** —— 菜单按最终形态整理（水波纹作为顶层项，前光与诊断收进「其他」）；README 面向发布重写；
  前光正式标注为"因需要 root 而终止实现，仅保留未实测测试路径"。
- **0.4.3** —— 修复 JNI 异常捕获顺序（pending 异常期间调用 JNI 会 abort 进程）；
  金丝雀标记带版本号；`settings` 等命令改用绝对路径。
- **0.4.0** —— 菜单回调全面 pcall 保护；新增 WRITE_SETTINGS 请求与设置键自动发现。
- **0.3.x** —— EPDC 改为反射式方法发现；前光后端独立金丝雀与面包屑；修复 `local _` 遮蔽 gettext。
- **0.2.0** —— 启动路径去除 JNI / 子进程 / 硬件探测；加入崩溃金丝雀与面包屑日志。
- **0.1.0** —— 初版。
